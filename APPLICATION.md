# moonhttp 项目申报书

## 基本信息

- 项目名称：moonhttp
- 参赛者：（待填）
- 联系方式：（待填）
- GitHub 仓库链接：https://github.com/q2316367743/moonhttp
- 项目方向：HTTP 客户端 / Web 与网络基础设施（通用工具库）
- 是否为移植项目：否。原创实现，API 语义参考 axios，未移植其代码

---

## 一、项目简介

moonhttp 是 MoonBit 上的 HTTP 客户端。它用 `moonbitlang/async` 负责真正的 I/O，在此之上补出端到端可用的高层 API：实例化的默认配置与四级合并策略、`request` / `stream` / `sse` 三个入口、四种请求体形态、自动重定向、代理隧道、上传下载进度回调、请求与响应拦截器、取消句柄，以及对齐 axios `ERR_*` 的错误模型。

目标使用者是需要在 MoonBit 里调用第三方 REST API、上传文件或消费 SSE 流的库作者与工具开发者。他们要的是一次配置就能发请求，而不是先把底层传输的类型读完。

---

## 二、项目方向与通用性

moonhttp 不绑定任何具体服务、协议扩展或业务领域——凡是"发一个 HTTP 请求、读一个响应"的场景都能直接用。它带来的可复用性是三层的：

- **配置层**：`Client` 实例持有一套默认值（`base_url`、超时、公共头、凭据），请求侧只写差异。多个 API 用多个实例，互不干扰。
- **契约层**：`Transport` trait + `RawResponse` 把底层运行时挡在后面，换实现不破坏上层 API。
- **解析层**：SSE 解析与 urlencoded / multipart 序列化是纯逻辑，可脱离网络单独测试，也能被别的基础设施复用。

它是被别的项目 `moon add` 引用的底座，不是一个应用。

---

## 三、项目价值与生态定位

### 生态现状（mooncakes.io，2026-09-24）

| 项目 | 层次 | 能力边界 |
|---|---|---|
| `moonbitlang/async` | 异步运行时 | 提供底层 HTTP 与流：传入 `uri` / `headers` / `proxy`，返回一个流 |
| `gaato/http` + `gaato/http-async` | Sans-IO 词汇层 + 传输原语 | `Request` 是扁平结构、需以完整 URL 构造；无实例与配置概念；无重定向 / multipart / urlencoded / 拦截器 / 代理 / 进度；错误模型 3 类。支持 Native / JS / Wasm 三后端 |
| `moonbitstack/moonhttp` | 协议编解码族 | HTTP/3 framing、HPACK/QPACK、WebSocket、SSE、multipart；"bytes in, events out; no sockets"，不含网络 I/O。与本项目同名但不同层，故不做对比 |

这三者分别是运行时、词汇层和编解码层。**在 mooncakes.io 上，没有一个是端到端可用的高层客户端**。

### 缺口

> **【待手写】** 你观察到了哪些具体的痛点？为什么在 MoonBit 当前生态下这个项目非做不可？
> 写一段你自己的真实经历：用 MoonBit 调某个 API 时具体卡在哪一步、被迫写了多少重复代码。这是全篇最重要的一段，评审看的就是它。避免"生态不完善""提升开发效率"这类空话。

### 优势

> **【待手写】** 如果存在竞品，你的优势体现在哪、它为什么重要？
> 事实已在上表。这一段用你自己的话讲清一件事：你要赢的不是"协议实现深度"（那是 `gaato/http` 与 `moonbitstack/moonhttp` 的地盘，主动让出去），而是"写一次就能跑起来的开发体验"。建议顺带说明为什么主动选择单后端（native）而不是追三后端。

---

## 四、预期使用场景

**场景一：CLI 工具与脚本调用第三方 REST API。** 写一个命令行工具从 GitHub API 拉仓库信息。用 `create()` 建实例，把 `base_url`、超时与公共头（`Accept`、`Authorization`）写进实例默认值，之后每次请求只写路径：`api.request(Config::new("/repos/moonbitlang/core"))`。分页参数交给 `with_params`，响应用 `json()` 显式解析。换一个 API 就 `create()` 一个新实例，两套配置互不干扰。仓库内 `src/cmd/main/main.mbt` 就是这个场景的可运行示例。

**场景二：对接需鉴权的后端并上传文件。** 一个数据上报工具，服务端要求 Basic 认证且接口收 `multipart/form-data`。实例上 `with_auth` 一次配好凭据，请求侧 `with_data_from_form` 构造表单——库自动生成 boundary 并补上 `Content-Type`，表单里的 `name` / `filename` 按 WHATWG 规则转义。文件以字节数组传入，库不读磁盘，调用方对 I/O 保持完全控制。

**场景三：消费 SSE 事件流。** 接一个大模型的流式输出接口，或订阅服务端的日志推送。用 `Client::sse` 拿到 `SseStream`，按 `next_event()` 逐个事件读，不必自己处理"一次 TCP 读到的字节正好切在事件中间"的边界情况（解析器按字节缓冲，跨块安全）。事件里的 `id` / `retry` 作为持久状态带出来，重连策略留在上层。

> **【待手写】** 可以再加一个你自己最想解决的场景，或把上面某个场景换成你亲身遇到的真实需求（带上具体的服务名、接口形态、你觉得麻烦的地方）。三个是章程的底线，细节越真实越好。

---

## 五、核心功能与交付范围

- **实例与配置合并**：`Client` 持有一套默认值（`base_url`、超时、公共头、凭据），每次请求在「内置默认值 → 实例默认值 → 本次请求」之间按四种策略合并（`valueFromConfig2` / `defaultToConfig2` / `mergeDeepProperties` / `mergeDirectKeys`），方法缺省走三级回退，行为对齐 axios `lib/core/mergeConfig.js`；`Config` 上 23 个 `with_*` 构建器开箱即用
- **三个入口与三种读法**：`request` / `stream` / `sse`；响应侧 `text()` / `bytes()` / `json()`
- **四种请求体形态**：`with_data_from_str` / `with_data_from_json` / `with_data_from_form`（multipart 表单，含文件上传）/ `with_data_from_urlencoded`，自动补 `Content-Type`
- **自动重定向**：`max_redirects` 默认 5 跳，含下一跳的方法 / body / 凭据 / `Host` 改写规则
- **代理**：`with_proxy`，CONNECT 隧道，代理凭据不泄漏给目标服务器
- **进度回调**：`with_on_upload_progress` / `with_on_download_progress`
- **拦截器**：请求 / 响应两段，响应段可挂 `on_rejected`
- **`paramsSerializer`**：独立配置项（`transformRequest` / `transformResponse` 由两段拦截器承担，配方见 `docs/11-interceptors.md`）
- **取消请求**：`CancelToken`（`new` / `cancel` / `is_cancelled` / `reason` / `attach`）经 `with_cancel_token` 传入，取消中的请求由传输层的取消作用域关闭
- **Basic 认证**：`with_auth`，以 `Authorization` 头落线，不覆盖用户显式设置的值
- **错误模型**：8 类 `ErrorCode`（`BadRequest` / `BadResponse` / `Network` / `Timeout` / `InvalidUrl` / `NotSupported` / `Cancelled` / `TooManyRedirects`）映射 axios `ERR_*`，错误上挂完整响应或已读到的部分
- **SSE 解析**：独立包，按字节缓冲、跨块安全，`id` / `retry` 作为持久状态带出
- **快捷方法**：`get` / `post` / `put` / `delete` / `head` / `options` / `patch`，在 `request` 之上固定方法名与 body 位置（收尾中）
- **工程配套**：`README` 可复现示例（`moon run src/cmd/main`）、`docs/` 12 篇技术文档 + 索引、覆盖核心路径的测试、CI 门禁（check / build / test，并对 `.mbti` 与 `moon fmt` 设门禁）、发布到 mooncakes.io

以上功能除标注「收尾中」的一条外均已完成：`moon test` 279 个用例全通过、`moon check --deny-warn` 零告警。

---

## 六、未来计划

以下能力经过评估后主动排到本版之外——它们都是刻意的取舍而非遗漏，理由同步记录在 README 的「暂不支持」与「与 axios 的其它差异」两节；本版配置里不会出现对应字段，避免"配置了但完全不生效"：

1. **连接池（请求池）**：当前每次请求新建连接，后续复用连接以省掉重复握手开销；
2. **cookie 复用**：`withCredentials` 与跨请求的 cookie 会话管理；
3. **流式上传**：以流而非整块字节数组提交请求体，支持超出内存的大文件；
4. **SSE 自动重连**：`id` / `retry` 作为持久状态带出的机制已经就位，重连策略目前留给上层，后续内置；
5. **响应体自动解析**：静态类型下"猜内容类型"的终点是让每个调用点自己 `match`，需要先重新设计响应类型的形态。

---

## 七、实现路径与技术理解

常见路径有三条：(1) 直接包一层 `moonbitlang/async` 的 http，最快，但把底层类型泄漏给使用者，换实现等于破坏 API；(2) 走 Sans-IO 路线，把 I/O 完全交给调用方（`gaato/http` 的选择），灵活但使用门槛高、开箱不可用；(3) 分层：底层 I/O 关在一个包里，上面建纯逻辑层。

**本项目选第三条。** 七个功能包按依赖方向构成 DAG：`transport` 是唯一接触 `moonbitlang/async` 的包，把底层类型挡在 `Transport` trait 与 `RawResponse` 契约之后（`MockTransport` 因此能在无网络下测试整条管线）；`url` / `config` 的序列化与合并规则是纯函数，可以脱离网络单独测试；门面类型（`Response` / `StreamResponse` / `SseStream` / `HttpError`）留在根包。

> **【待手写】** 完成实现需要哪些能力？你有没有一些独到的理解？
> 挑一个你真的想过的技术判断讲透，例如：为什么 `Config.data` 做成私有字段（`Json::String` 的歧义、`Content-Type` 必须与 body 配套）、为什么响应体不自动解析（静态类型下"猜内容类型"的终点只能是让每个调用点自己 match）、为什么 `json()` 的失败抛 `ParseError` 而不是 `HttpError`。任选一个讲透，比铺开讲十个都有说服力。

---

## 八、参考与许可说明

- 参考项目名称：axios（`axios/axios`）
- 参考项目链接：https://github.com/axios/axios
- 参考项目许可证：MIT
- 本项目许可证：Apache-2.0（OSI 认可）
- 参考方式：仅参考其公开 API 语义与错误码命名，**未移植、未复制任何源代码**；合并策略等行为差异逐条记录在 README 的「与 axios 的差异」一节。

---

## 九、工程现状

| 指标 | 数值 |
|---|---|
| 有效提交 | 24（均在赛期内；取消请求的改动已完成，待提交） |
| 包数 / 源码行数 | 7 个功能包 + 1 个示例包 / 约 6,200 行（不含测试） |
| 测试 | 279 个，全部通过（`moon test`，30 个测试文件） |
| 静态检查 | `moon check --deny-warn` 零告警 |
| 技术文档 | `docs/` 12 篇（01–12）+ 索引 |
| 持续集成 | `.github/workflows/`：check / build / test，并对 `.mbti` 与 `moon fmt` 设门禁 |
| 许可证 | Apache-2.0（OSI 认可） |

> **【待手写】** 最后通读一遍整篇，把不像你自己说话的地方改掉。章程明确写着"明显包含 AI 套话或没有体现选手对选题有深刻认识的申报书会在审核阶段被驳回"，所以宁可句子粗糙一点，也要是你自己的判断。
