param(
  [string]$BaseUrl = "http://127.0.0.1:5001",
  [string]$AdminKey = $(if ($env:DS2API_ADMIN_KEY) { $env:DS2API_ADMIN_KEY } else { "admin" }),
  [string]$OutDir = ".\tmp-captures",
  [int]$Index = 0,
  [string]$Query = "",
  [int]$Limit = 10,
  [switch]$List,
  [switch]$Clear,
  [switch]$SaveSample,
  [string]$SampleId = "",
  [string]$CaptureId = "",
  [string]$ChainKey = ""
)

$ErrorActionPreference = "Stop"

function Join-Url {
  param([string]$Root, [string]$Path)
  return $Root.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Invoke-AdminLogin {
  $body = @{
    admin_key = $AdminKey
    expire_hours = 24
  } | ConvertTo-Json -Compress

  $loginUrl = Join-Url $BaseUrl "/admin/login"
  $login = Invoke-RestMethod -Method Post -Uri $loginUrl -ContentType "application/json" -Body $body
  if (-not $login.token) {
    throw "Admin login succeeded but no token was returned."
  }
  return $login.token
}

function Get-Captures {
  param([string]$Jwt)
  $url = Join-Url $BaseUrl "/admin/dev/captures"
  return Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $Jwt" }
}

function Write-TextFile {
  param([string]$Path, [AllowNull()][object]$Value)
  $text = ""
  if ($null -ne $Value) {
    $text = [string]$Value
  }
  $text | Set-Content -Encoding UTF8 $Path
}

function Write-PrettyJson {
  param([string]$Path, [AllowNull()][object]$Value, [int]$Depth = 64)
  if ($null -eq $Value) {
    "" | Set-Content -Encoding UTF8 $Path
    return
  }
  $Value | ConvertTo-Json -Depth $Depth | Set-Content -Encoding UTF8 $Path
}

function Try-ParseJson {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return $null
  }
  try {
    return $Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Extract-VisibleOutput {
  param([string]$ResponseBody)

  $builder = New-Object System.Text.StringBuilder
  foreach ($line in ($ResponseBody -split "`r?`n")) {
    if (-not $line.StartsWith("data: ")) {
      continue
    }
    $json = $line.Substring(6).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
      continue
    }
    try {
      $obj = $json | ConvertFrom-Json
    } catch {
      continue
    }
    if (($null -eq $obj.p -or [string]::IsNullOrWhiteSpace([string]$obj.p)) -and $obj.v -is [string]) {
      [void]$builder.Append($obj.v)
      continue
    }
    if ($obj.p -eq "response/fragments/-1/content" -and $obj.v -is [string]) {
      [void]$builder.Append($obj.v)
    }
  }
  return $builder.ToString()
}

function Save-CaptureFiles {
  param([object]$Item, [string]$Destination)

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null

  $request = Try-ParseJson ([string]$Item.request_body)
  $visible = Extract-VisibleOutput ([string]$Item.response_body)

  $meta = [ordered]@{
    id = $Item.id
    created_at = $Item.created_at
    label = $Item.label
    url = $Item.url
    account_id = $Item.account_id
    status_code = $Item.status_code
    response_truncated = $Item.response_truncated
  }
  if ($null -ne $request) {
    $meta.model_type = $request.model_type
    $meta.chat_session_id = $request.chat_session_id
    $meta.parent_message_id = $request.parent_message_id
    $meta.max_tokens = $request.max_tokens
    $meta.thinking_enabled = $request.thinking_enabled
    $meta.search_enabled = $request.search_enabled
    $meta.ref_file_count = @($request.ref_file_ids).Count
    if ($request.prompt) {
      $meta.prompt_chars = ([string]$request.prompt).Length
    }
  }
  $meta.visible_output_chars = $visible.Length

  Write-PrettyJson (Join-Path $Destination "latest-meta.json") $meta 16
  Write-TextFile (Join-Path $Destination "latest-request-body.json") $Item.request_body
  Write-TextFile (Join-Path $Destination "latest-response-body.txt") $Item.response_body
  Write-TextFile (Join-Path $Destination "latest-visible-output.txt") $visible
  if ($null -ne $request -and $request.prompt) {
    Write-TextFile (Join-Path $Destination "latest-prompt.txt") $request.prompt
  }

  return $meta
}

function Show-CaptureSummary {
  param([object]$Capture)

  $items = @($Capture.items)
  Write-Host ("enabled={0} limit={1} max_body_bytes={2} items={3}" -f $Capture.enabled, $Capture.limit, $Capture.max_body_bytes, $items.Count)
  for ($i = 0; $i -lt $items.Count; $i++) {
    $item = $items[$i]
    $req = Try-ParseJson ([string]$item.request_body)
    $promptChars = ""
    $session = ""
    if ($null -ne $req) {
      $session = [string]$req.chat_session_id
      if ($req.prompt) {
        $promptChars = ([string]$req.prompt).Length
      }
    }
    Write-Host ("[{0}] {1} status={2} truncated={3} label={4} session={5} prompt_chars={6}" -f $i, $item.id, $item.status_code, $item.response_truncated, $item.label, $session, $promptChars)
  }
}

function Query-CaptureChains {
  param([string]$Jwt)

  $encoded = [uri]::EscapeDataString($Query)
  $url = Join-Url $BaseUrl ("/admin/dev/raw-samples/query?q={0}&limit={1}" -f $encoded, $Limit)
  $result = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $Jwt" }
  Write-Host ("query='{0}' count={1}" -f $result.query, $result.count)
  $items = @($result.items)
  for ($i = 0; $i -lt $items.Count; $i++) {
    $item = $items[$i]
    Write-Host ("[{0}] chain_key={1} rounds={2} truncated={3}" -f $i, $item.chain_key, $item.round_count, $item.response_truncated)
    Write-Host ("    captures: {0}" -f (($item.capture_ids -join ", ")))
    Write-Host ("    request : {0}" -f $item.request_preview)
    Write-Host ("    response: {0}" -f $item.response_preview)
  }
}

function Save-RawSample {
  param([string]$Jwt)

  $body = @{}
  if (-not [string]::IsNullOrWhiteSpace($CaptureId)) {
    $body.capture_id = $CaptureId
  } elseif (-not [string]::IsNullOrWhiteSpace($ChainKey)) {
    $body.chain_key = $ChainKey
  } elseif (-not [string]::IsNullOrWhiteSpace($Query)) {
    $body.query = $Query
  } else {
    $capture = Get-Captures $Jwt
    $items = @($capture.items)
    if ($items.Count -eq 0) {
      throw "No captures are available to save."
    }
    $body.capture_id = $items[$Index].id
  }

  if (-not [string]::IsNullOrWhiteSpace($SampleId)) {
    $body.sample_id = $SampleId
  }

  $url = Join-Url $BaseUrl "/admin/dev/raw-samples/save"
  $saved = Invoke-RestMethod -Method Post -Uri $url -Headers @{ Authorization = "Bearer $Jwt" } -ContentType "application/json" -Body ($body | ConvertTo-Json -Compress)
  Write-PrettyJson (Join-Path $OutDir "latest-sample-save.json") $saved 16
  Write-Host ("saved sample_id={0}" -f $saved.sample_id)
  Write-Host ("sample_dir={0}" -f $saved.sample_dir)
}

$jwt = Invoke-AdminLogin

if ($Clear) {
  $url = Join-Url $BaseUrl "/admin/dev/captures"
  Invoke-RestMethod -Method Delete -Uri $url -Headers @{ Authorization = "Bearer $jwt" } | ConvertTo-Json -Depth 8
  exit 0
}

if (-not [string]::IsNullOrWhiteSpace($Query) -and -not $SaveSample) {
  Query-CaptureChains $jwt
  exit 0
}

if ($SaveSample) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Save-RawSample $jwt
  exit 0
}

$capture = Get-Captures $jwt
if ($List) {
  Show-CaptureSummary $capture
  exit 0
}

$items = @($capture.items)
if ($items.Count -eq 0) {
  Write-Host "No captures found. Send a request through DS2API first."
  exit 1
}
if ($Index -lt 0 -or $Index -ge $items.Count) {
  throw "Index $Index is out of range. Capture count: $($items.Count)."
}

$meta = Save-CaptureFiles $items[$Index] $OutDir
Write-Host ("saved capture {0} to {1}" -f $items[$Index].id, (Resolve-Path $OutDir))
Write-Host ("prompt_chars={0} response_truncated={1} visible_output_chars={2}" -f $meta.prompt_chars, $meta.response_truncated, $meta.visible_output_chars)
