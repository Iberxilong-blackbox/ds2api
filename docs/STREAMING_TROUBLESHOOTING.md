# 流式输出截断排查记录

本文记录一次本地 WebUI API Tester 流式输出疑似截断的排查过程，方便后续遇到类似问题时快速定位。该问题不一定稳定复现，但排查路径可以复用。

## 现象

在 WebUI API Tester 中开启流式模式，使用模型：

```text
deepseek-v4-flash-nothinking
```

请求：

```text
tell me a joke
```

曾观察到 WebUI 展示结果类似：

```text
Why don scientists.
```

关闭流式模式后，同一类请求可以得到完整回答：

```text
Why don't scientists trust atoms?
Because they make up everything.
```

## 初步判断

如果非流式正常、流式异常，优先不要直接归因到账号、模型或代理。更合理的排查范围是：

```text
DeepSeek 上游 SSE
-> DS2API 后端 SSE 解析/转换
-> WebUI API Tester 流式读取/展示
```

## 快速分界线

排查时重点比较三处结果：

1. WebUI API Tester 展示内容
2. `curl -N` 看到的原始流式 SSE 内容
3. Admin Chat History 中后端记录的内容

判断方式：

```text
curl 流式完整，WebUI 不完整
=> 优先怀疑 WebUI 流式读取/展示逻辑。

curl 流式不完整，Chat History 也不完整
=> 优先怀疑后端 SSE 消费、转换，或上游实际返回不完整。

curl 流式完整，Chat History 完整，只有 WebUI 不完整
=> 基本可定位到前端 API Tester。

非流式也不完整
=> 不再是单纯流式问题，需检查上游输出、prompt、账号、内容过滤等因素。
```

## 复现与验证命令

建议在 PowerShell 中先设置本地测试 API Key。该值必须等于 `config.json` 中 `keys` / `api_keys[].key` 之一。

```powershell
$env:DS2API_TEST_API_KEY="local-test"
```

构造非流式请求：

```powershell
$body = @{
  model = "deepseek-v4-flash-nothinking"
  messages = @(
    @{
      role = "user"
      content = "tell me a joke"
    }
  )
  stream = $false
} | ConvertTo-Json -Compress

curl.exe http://127.0.0.1:5001/v1/chat/completions `
  -H "Content-Type: application/json" `
  -H "Authorization: Bearer $env:DS2API_TEST_API_KEY" `
  -d $body
```

构造流式请求：

```powershell
$body = @{
  model = "deepseek-v4-flash-nothinking"
  messages = @(
    @{
      role = "user"
      content = "tell me a joke"
    }
  )
  stream = $true
} | ConvertTo-Json -Compress

curl.exe -N http://127.0.0.1:5001/v1/chat/completions `
  -H "Content-Type: application/json" `
  -H "Authorization: Bearer $env:DS2API_TEST_API_KEY" `
  -d $body
```

正常流式响应应包含多段 `data:`，最后应出现：

```text
data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],...}

data: [DONE]
```

如果缺少 `finish_reason: "stop"` 或 `data: [DONE]`，需要进一步检查连接是否提前中断、代理是否影响长连接、后端是否提前 finalize。

## 本次观察到的重要线索

一次正常的 `curl -N` 流式响应中，某个 SSE 事件的 `choices` 数组包含多个 delta：

```json
{
  "choices": [
    { "delta": { "content": " don" }, "index": 0 },
    { "delta": { "content": "’" }, "index": 0 },
    { "delta": { "content": "t" }, "index": 0 },
    { "delta": { "content": " scientists" }, "index": 0 }
  ]
}
```

如果前端只处理：

```js
const choice = json.choices?.[0]
```

就会丢掉同一事件中的后续 delta，导致展示内容缺字或看起来像被截断。

更稳妥的处理方式应遍历全部 choices：

```js
for (const choice of json.choices || []) {
  const delta = choice?.delta
  if (!delta) continue

  if (delta.reasoning_content) {
    accumulatedThinking += delta.reasoning_content
    setStreamingThinking(prev => prev + delta.reasoning_content)
  }

  if (delta.content) {
    accumulatedContent += delta.content
    setStreamingContent(prev => prev + delta.content)
  }
}
```

相关前端位置：

```text
webui/src/features/apiTester/useChatStreamClient.js
```

相关后端流式位置：

```text
internal/httpapi/openai/chat/empty_retry_runtime.go
internal/httpapi/openai/chat/chat_stream_runtime.go
internal/stream/engine.go
internal/sse/parser.go
internal/sse/consumer.go
```

## 代理排查

本地访问 DS2API 不需要代理：

```text
browser/curl -> http://127.0.0.1:5001
```

代理只可能影响：

```text
DS2API 后端 -> DeepSeek 上游
```

如果怀疑代理影响 SSE 长连接，可以做 A/B 测试。

不走代理启动：

```powershell
Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:ALL_PROXY -ErrorAction SilentlyContinue
$env:NO_PROXY="127.0.0.1,localhost"

go run ./cmd/ds2api
```

走代理启动：

```powershell
$env:HTTP_PROXY="http://127.0.0.1:7890"
$env:HTTPS_PROXY="http://127.0.0.1:7890"
$env:NO_PROXY="127.0.0.1,localhost"

go run ./cmd/ds2api
```

如果两种方式下 `curl -N` 都完整，则代理不是主要原因。

## API Key 排查补充

`GET /v1/models` 当前可直接返回模型列表，不能证明聊天接口的 API Key 已通过鉴权。真正的鉴权验证应使用：

```text
POST /v1/chat/completions
```

如果聊天接口返回：

```json
{
  "error": {
    "message": "Invalid token. If this should be a DS2API key, add it to config.keys first."
  }
}
```

优先检查：

1. `Authorization: Bearer ...` 是否为空。
2. 当前 key 是否同时存在于 `config.json` 的 `keys` 和 `api_keys[].key` 中。
3. 服务是否读取的是当前项目根目录下的 `config.json`。
4. 是否设置了 `DS2API_CONFIG_JSON` 覆盖文件配置。
5. 修改配置后是否重启了 `go run ./cmd/ds2api`。

建议显式指定配置文件路径启动：

```powershell
$env:DS2API_CONFIG_PATH="C:\My_project\ds2api\config.json"
go run ./cmd/ds2api
```

## 结论模板

遇到类似问题时，可以按以下格式记录结论：

```text
非流式结果：完整 / 不完整
curl -N 流式结果：完整 / 不完整
WebUI 流式展示：完整 / 不完整
Chat History 后端记录：完整 / 不完整
是否走代理：是 / 否
模型：deepseek-v4-flash-nothinking
初步定位：前端展示 / 后端 SSE / 上游输出 / 网络代理 / 鉴权配置
```

本次排查的临时结论：

```text
非流式：完整
curl -N 流式：完整
WebUI 流式：曾出现不完整
初步定位：WebUI API Tester 流式展示逻辑可能只处理 choices[0]，未遍历同一 SSE 事件中的所有 choices delta。
```

