# DS2API 项目学习路线

本文档面向刚克隆本项目、希望系统理解代码结构和核心实现的学习者。建议先把项目看成一个“多协议 AI API 兼容网关”：客户端用 OpenAI / Claude / Gemini 风格发请求，DS2API 负责鉴权、模型别名映射、请求格式归一化、工具调用处理、流式输出解析、多账号调度，然后转成 DeepSeek Web 对话能力可理解的形式。

## 一、先建立整体认知

先读：

1. [项目总览 README](../README.MD)
2. [架构与目录说明](./ARCHITECTURE.md)
3. [接口文档 API](../API.md)

本阶段目标不是读懂每一行代码，而是回答这些问题：

- 这个项目为什么不只是一个简单反向代理？
- 它兼容了哪些客户端协议？
- OpenAI / Claude / Gemini 请求最后是否会汇入同一条核心链路？
- `config.json` 里哪些配置影响鉴权、账号、模型映射和运行时行为？
- `/healthz`、`/readyz`、`/admin`、`/v1/chat/completions` 分别服务什么场景？

## 二、理解服务入口和路由装配

重点文件：

- [`cmd/ds2api/main.go`](../cmd/ds2api/main.go)
- [`internal/server/router.go`](../internal/server/router.go)

建议阅读顺序：

1. 从 `main.go` 看服务如何加载配置、构建 WebUI、初始化应用、监听端口和优雅退出。
2. 进入 `server.NewApp()`，看 `Store`、`Pool`、`Resolver`、`DS Client`、各协议 handler 如何被装配。
3. 看路由注册，确认 OpenAI、Claude、Gemini、Admin、WebUI 的入口位置。

引导问题：

- 为什么 `main.go` 只负责启动和生命周期，而不直接写业务逻辑？
- `server.NewApp()` 初始化了哪些核心对象？它们之间是什么依赖关系？
- 为什么 OpenAI、Claude、Gemini handler 都共享同一个 DeepSeek client？
- 中间件里 CORS、Recoverer、Logger、RequestID 分别解决什么问题？

## 三、理解核心请求链路

推荐把一次请求按下面的路径追踪：

```text
client request
-> internal/server/router.go
-> internal/httpapi/openai/chat
-> internal/promptcompat
-> internal/auth
-> internal/account
-> internal/deepseek/client
-> internal/stream / internal/sse
-> internal/toolcall / internal/toolstream
-> response back to client
```

优先看 OpenAI Chat Completions，因为它是最直观、最常见的入口。

重点目录：

- [`internal/httpapi/openai/chat`](../internal/httpapi/openai/chat)
- [`internal/promptcompat`](../internal/promptcompat)
- [`internal/auth`](../internal/auth)
- [`internal/account`](../internal/account)
- [`internal/deepseek/client`](../internal/deepseek/client)
- [`internal/stream`](../internal/stream)
- [`internal/sse`](../internal/sse)

引导问题：

- 一个 `/v1/chat/completions` 请求从 handler 到 DeepSeek 上游经历了哪些转换？
- 非流式和流式请求的处理路径有哪些共同点和差异？
- 请求失败时，错误是在哪一层被转换成客户端兼容格式的？

## 四、学习协议适配层

协议适配层负责把外部世界的不同请求格式归一到内部可复用语义。

重点目录：

- [`internal/httpapi/openai`](../internal/httpapi/openai)
- [`internal/httpapi/claude`](../internal/httpapi/claude)
- [`internal/httpapi/gemini`](../internal/httpapi/gemini)
- [`internal/translatorcliproxy`](../internal/translatorcliproxy)

引导问题：

- OpenAI 的 `messages`、Claude 的 `messages`、Gemini 的 `contents` 差异在哪里？
- 项目在哪里做模型别名映射？
- Claude / Gemini 为什么不各自实现完整上游调用逻辑？
- 这种设计如何体现 DRY：协议入口可以不同，但核心执行链路尽量复用。

学习重点：

- OpenAI 是主参考协议面。
- Claude / Gemini 更多承担协议转换和输出格式适配。
- 真正和 DeepSeek 通信的能力不应该在多个协议 handler 中重复出现。

## 五、重点攻克 PromptCompat

`internal/promptcompat` 是本项目最核心的学习区域之一。它负责把结构化 API 请求转换成 DeepSeek Web 对话可理解的纯文本上下文。

重点文件与文档：

- [`internal/promptcompat`](../internal/promptcompat)
- [`internal/prompt`](../internal/prompt)
- [`docs/prompt-compatibility.md`](./prompt-compatibility.md)

引导问题：

- 什么叫“API -> 网页对话纯文本上下文”？
- 为什么不能直接把 OpenAI / Claude / Gemini 的原始结构发给上游？
- system / user / assistant / tool 消息如何被归一化和拼接？
- 长历史为什么要拆分或文件化？
- Tool Prompt 是如何注入的？
- 如果 `promptcompat` 出错，会影响哪些接口？

建议关注的原则：

- KISS：先理解标准请求归一化，再看特殊兼容分支。
- DRY：多协议请求最终应复用同一套 prompt 构建语义。
- SRP：消息归一化、历史处理、工具提示注入应各自承担清晰职责。

## 六、理解账号、鉴权和并发模型

本阶段关注服务稳定性：客户端如何被鉴权，DeepSeek 账号如何被调度，一个账号满载时系统如何处理。

重点目录：

- [`internal/config`](../internal/config)
- [`internal/auth`](../internal/auth)
- [`internal/account`](../internal/account)

引导问题：

- 客户端 API Key 和 DeepSeek 账号 token 是同一个东西吗？
- `auth.Resolver` 解决的是客户端鉴权，还是上游账号选择？
- 账号池如何决定使用哪个账号？
- 每账号 in-flight 限制在哪里实现？
- 等待队列如何避免请求直接失败？
- token 过期时在哪里刷新？

学习重点：

- 配置加载和热更新是系统运行的基础。
- 鉴权和账号池不要混成一个概念。
- 并发控制是这个项目从“能跑”到“稳定跑”的关键。

## 七、理解 DeepSeek 上游通信和流式输出

这一部分解释请求真正发往上游后，响应如何被解析并转换回客户端兼容格式。

重点目录：

- [`internal/deepseek/client`](../internal/deepseek/client)
- [`internal/deepseek/protocol`](../internal/deepseek/protocol)
- [`internal/deepseek/transport`](../internal/deepseek/transport)
- [`internal/stream`](../internal/stream)
- [`internal/sse`](../internal/sse)
- [`internal/format`](../internal/format)

引导问题：

- DeepSeek 上游 SSE 和 OpenAI SSE 有什么不同？
- 项目在哪里解析 SSE 行？
- 上游 completion、continue、session、upload 分别由哪些文件处理？
- 非流式响应是否也复用了流式语义？
- 内容过滤、空响应、继续生成等边界状态在哪里处理？

## 八、Tool Calling 专题

Tool Calling 是项目难点，也是最值得深入学习的部分之一。

重点目录与文档：

- [`internal/toolcall`](../internal/toolcall)
- [`internal/toolstream`](../internal/toolstream)
- [`docs/toolcall-semantics.md`](./toolcall-semantics.md)
- [`internal/js/helpers/stream-tool-sieve`](../internal/js/helpers/stream-tool-sieve)

引导问题：

- 为什么 README 强调 DSML / canonical XML？
- 模型输出工具调用时，系统如何避免工具 XML 泄漏给用户？
- `delta.tool_calls` 为什么需要尽早发出？
- 流式输出中，如何判断一段文本是普通内容还是工具调用片段？
- Go 和 Node 两套 tool sieve 为什么要保持语义一致？

学习重点：

- 先理解完整工具调用结构，再看流式增量解析。
- 防泄漏逻辑比普通文本解析更复杂，需要结合测试样本阅读。
- 工具调用相关改动通常需要同步看 Go、Node、测试夹具和文档。

## 九、WebUI 和 Admin API

WebUI 是管理端体验，不建议作为第一阶段学习入口。等后端主链路清楚后，再看它如何调用 Admin API。

重点目录：

- [`internal/httpapi/admin`](../internal/httpapi/admin)
- [`internal/webui`](../internal/webui)
- [`webui`](../webui)

引导问题：

- Admin API 提供了哪些资源管理能力？
- WebUI 的配置模板为什么复用 `config.example.json`？
- 账号测试、代理管理、运行时设置、历史记录分别对应哪些后端资源？
- 前端只是展示和调用，还是也承担了业务规则？

## 十、测试和质量门禁

重点文档：

- [`docs/TESTING.md`](./TESTING.md)
- [`AGENTS.md`](../AGENTS.md)

本仓库要求 PR 前运行：

```bash
./scripts/lint.sh
./tests/scripts/check-refactor-line-gate.sh
./tests/scripts/run-unit-all.sh
npm run build --prefix webui
```

引导问题：

- 哪些测试是协议兼容测试？
- 哪些测试是流式和 tool call 边界测试？
- 为什么这个项目有 Go 测试，也有 Node 测试？
- 当你修改 `promptcompat`、`toolcall`、`stream` 时，应该优先跑哪些测试？

## 十一、最值得研究的关键问题

1. 如何把 OpenAI / Claude / Gemini 三种协议统一到一套内部执行模型？
2. 如何把结构化聊天请求转换成 DeepSeek Web 可用的纯文本上下文？
3. 如何在流式输出里稳定识别工具调用，并避免工具调用文本泄漏？
4. 如何管理多个账号的并发、排队和 token 刷新？
5. 如何让同一个服务同时适配本地、Docker、Vercel 和 WebUI 管理场景？

## 十二、推荐阅读顺序

1. [`README.MD`](../README.MD)
2. [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md)
3. [`cmd/ds2api/main.go`](../cmd/ds2api/main.go)
4. [`internal/server/router.go`](../internal/server/router.go)
5. [`internal/httpapi/openai/chat`](../internal/httpapi/openai/chat)
6. [`internal/promptcompat`](../internal/promptcompat)
7. [`internal/deepseek/client`](../internal/deepseek/client)
8. [`internal/stream`](../internal/stream)
9. [`internal/sse`](../internal/sse)
10. [`internal/toolcall`](../internal/toolcall)
11. [`internal/toolstream`](../internal/toolstream)
12. [`webui`](../webui)

## 十三、学习时的实践建议

- 每读一个模块，先写出“它接收什么、输出什么、依赖什么”。
- 优先沿一次真实请求追踪代码，不要按目录逐个文件平铺阅读。
- 修改代码前先找对应测试，测试通常比文档更能暴露边界行为。
- 遇到复杂分支时，先判断它是协议兼容、上游兼容、部署兼容，还是历史行为兼容。
- 读完一个阶段后，用自己的话回答本阶段引导问题；答不出来再回到对应文件。

