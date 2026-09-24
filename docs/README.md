# 技术文档索引

本目录记录 `moonhttp` 的实现思路、关键文件、数据结构 / API 契约与注意事项，供后续开发（含 AI 协作）快速接管。

面向使用者的入门文档在仓库根目录的 [README.mbt.md](../README.mbt.md)；本目录面向维护者，重点回答「为什么这样设计」和「改动时要同步什么」。

| 编号 | 文档 | 内容 | 什么时候读 |
|---|---|---|---|
| 01 | [架构与分层](01-architecture.md) | 目录结构、八个包的职责与依赖方向、为什么把 async 关在一层、为什么测试文件不能挪出包目录、为什么实现层不能整体搬进子包（`pub using` 再导出不了错误构造子）而纯逻辑可以独立成 `util`、如何新增一个配置字段或一个新包 | 要动手改代码之前 |
| 02 | [配置合并契约](02-config-merge.md) | axios `mergeConfig` 四种策略在本项目的落法、字段归属表、`Option` 与 `undefined` 的对应、数组替换语义 | 要改合并行为、或要新增配置字段时 |
| 03 | [请求管线](03-request-pipeline.md) | 三种读法（`request` / `stream` / `sse`）的分工、八个步骤、URL 拼接与 query 序列化规则、body 序列化与自动补头、`response_encoding` 如何决定 `data`（以及为什么不做 JSON 解析）、状态码校验 | 要改请求行为（URL、头的优先级、body 处理、响应解码）时 |
| 04 | [错误契约](04-errors.md) | `HttpError` / `ErrorCode` 形状、与 axios 错误码的对应、各类错误的触发点、错误里带什么上下文（完整响应 / 失败前已收到的部分 / `None`） | 要新增错误分类或调整错误信息时 |
| 05 | [传输层契约](05-transport.md) | `Transport` trait 与 `PreparedRequest` / `RawResponse` 字段含义、`ResponseBody` 响应体流的读语义（含 `read_all_partial` 的半截字节）与超时语义、`AsyncHttpTransport` 的实现注意事项、如何写自定义传输 | 要换 HTTP 实现、加连接池 / 代理 / 上传进度，或要动流式读取时 |
| 06 | [SSE 事件解析](06-sse.md) | 为什么 `read_until("\n\n")` 切不了 SSE、为什么解析器独立成包、为什么按事件读是独立类型、`SseEvent` / `SseParser` 的公开 API、EventSource 规范逐条落点、`id` / `retry` 的持久状态、跨块安全与 `finish()`、不自动重连的边界 | 要改 SSE 行为、接新的 SSE 服务端，或要加自动重连时 |

## 改动时的同步清单

改代码时容易被漏掉的联动项，集中写在这里：

1. **新增配置字段**：`Config` 加字段 → 在 `merge_config` 里显式选一档合并策略 → 需要的话加 `with_*` 构建器与 `Config::to_string` 渲染 → 若参与请求，接到 `src/util/request.mbt` 的 `build_prepared_request` 或 `src/client.mbt` 的 `build_response` → 补测试（`merge` 包测合并、根包测端到端）→ 更新 `02-config-merge.md` 的字段归属表。
2. **新增包**：确认依赖方向仍是 DAG（见 `01-architecture.md`）→ 新包若暴露新类型，用 `pub using` 再导出 → 根包 `moon.pkg` 加 import → 更新 README 与 `01-architecture.md` 的目录树。**注意**：新包不能依赖根包的门面类型（`Response` / `StreamResponse` / `SseStream` / `HttpError` / `ErrorCode`），否则与根包成环；`util` 包的准入条件写在 `src/util/moon.pkg` 里。
3. **改公开 API**：跑 `moon info` 后检查 `pkg.generated.mbti` 的 diff，确认只包含预期的变化。
4. **对接底层库（`moonbitlang/async`）的改动**：只允许出现在 `src/transport/` 这个包里（`async_http.mbt` 是主要落点，`stream.mbt` 负责响应体流的读写封装）；如果发现必须让上层认识底层类型，说明抽象漏了，应当先补 `Transport` / `ResponseBody` 契约。
5. **改 `RawResponse` 或 `ResponseBody` 的结构 / 语义**：它们出现在公开签名里，要同步 `05-transport.md`、`03-request-pipeline.md`，并检查根包三个入口（`request` 读全量、`stream` 不读、`sse` 按事件读）是否都还成立；`MockTransport` 的响应体必须仍能用 `ResponseBody::from_bytes` 造出来。
6. **改超时相关的行为**：超时在两处生效（响应头阶段整体、响应体读取），且响应体读取里 `read_all` / `read_all_partial`（整段读完一个时限）与 `read_some` / `read_until`（每次等待一个时限）口径不同，见 `05-transport.md` 的「超时语义」。改任何一处都要同时看另一处与非流式路径的既有行为。SSE 依赖「不限时」这个前提，见 `06-sse.md`。
7. **改响应解码（`response_encoding` / `decode_body`）**：四种编码的分派在 `src/util/response.mbt` 的 `decode_body`，拼进 `Response` 在 `src/client.mbt` 的 `build_response`，用例在 `src/encoding_test.mbt`。三条别动的前提：解码一律 lossy（非法字节 → `U+FFFD`，不抛错）、`Response::data` 是原文**不做 JSON 解析**（要 JSON 请调用方自己 `@json.parse`）、这个字段只作用于「读全量」的 `Client::request`。改动要同步 `03-request-pipeline.md` 的表格与 `README.mbt.md`。
8. **新增失败路径（抛 `HttpError` 的地方）**：先问一句「这时已经收到多少响应」。响应头到手之后的失败一律把已经收到的响应挂上去（`transport_error(error, config, Some(...))` / `make_error(..., Some(response))`），不要图省事传 `None`；读到一半失败时用 `ResponseBody::read_all_partial` 保住已读到的字节。这条规则与用例见 `04-errors.md`。
9. **改 SSE 解析**：解析规则在 `src/sse/`（独立包，同步测试在 `src/sse/sse_test.mbt`），接到 HTTP 上的部分在 `src/facade.mbt`（`SseStream`）/ `src/client.mbt`（`Client::sse`）。先补用例再改代码；CRLF 家族（裸 CR 收尾、CR 跨块）最容易改坏。同步 `06-sse.md`。
10. **想给 `StreamResponse` 加「按事件读」的方法**：不要这样做。它是下载用的原始字节流，把二进制喂给事件解析器只会解出无意义的东西；SSE 有独立的 `SseStream` 与 `Client::sse`，理由见 `06-sse.md`。
