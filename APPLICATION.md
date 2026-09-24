# moonhttp 项目申报书

| 项 | 内容 |
|---|---|
| 项目名称 | moonhttp |
| 项目方向 | 通用工具库 / Web 与网络基础设施 |
| 项目类型 | 原创实现。API 语义参考 axios，未移植其代码 |
| GitHub 仓库 | https://github.com/q2316367743/moonhttp （公开，14 个有效提交） |
| 开源许可证 | Apache-2.0 |
| 参赛形式 | 个人 |

## 一、项目简介

moonhttp 是一个 axios 风格的 MoonBit HTTP 客户端，为 `moonbitlang/async` 的底层 HTTP 能力补上端到端可用的高层 API：实例化的默认配置与四种合并策略、四种请求体形态、`request` / `stream` / `sse` 三个入口与响应体的三种读法、自动重定向、映射 axios `ERR_*` 的错误模型。

## 二、项目价值与生态定位

### 生态现状（据 mooncakes.io，2026-09-24）

| 项目 | 层次 | 公开接口 | 能力边界 |
|---|---|---|---|
| `moonbitlang/async` | 异步运行时 | — | 提供底层 HTTP；本项目以其为传输实现 |
| `gaato/http` + `gaato/http-async` | Sans-IO 词汇层 + 传输原语 | 91 行 / 33 行 | `Request` 是扁平结构、需以完整 URL 构造；无实例与配置概念，无重定向、multipart、urlencoded；错误模型 3 类 |
| `moonbitstack/moonhttp` | 协议编解码族 | — | HTTP/3 framing、HPACK/QPACK、WebSocket、SSE、multipart；"bytes in, events out; no sockets"，不含网络 I/O |

三者分别覆盖「运行时」「词汇层」「编解码层」，**没有一个是端到端可用的高层客户端** —— 使用者仍要自己拼 URL、管理公共头、判断状态码、跟随重定向、决定响应体怎么解。

> 【手写】你观察到了哪些具体的痛点？为什么在 MoonBit 当前生态下这个项目非做不可？
> 建议写一段你自己的真实经历：在用 MoonBit 调某个 API 时，具体卡在哪一步、被迫写了多少重复代码。这是全篇最重要的一段，评审看的就是它。避免"生态不完善""提升开发效率"这类空话。

### 本项目补齐的生态位

配置层：`Client` 实例持有一套默认配置，每次请求在「内置默认值 → 实例默认值 → 本次请求」之间按四种策略合并（`valueFromConfig2` / `defaultToConfig2` / `mergeDeepProperties` / `mergeDirectKeys`），行为对齐 axios `lib/core/mergeConfig.js`；`Config` 上 19 个 `with_*` 构建器开箱即用。

> 【手写】如果存在"竞品"，你的优势体现在哪、它为什么重要？
> 上面那张表已经把事实摆好了。这一段请用你自己的话讲清楚一件事：你要赢的不是"协议实现深度"（那是 moonbitstack/moonhttp 的地盘，主动让出去），而是"写一次就能跑起来的开发体验"。

## 三、预期使用场景

**场景一：CLI 工具与脚本调用第三方 REST API。** 例如写一个命令行工具从 GitHub API 拉取仓库信息。用 `create()` 建一个实例，把 `base_url`、超时与公共头（`Accept`、`Authorization`）写进实例默认值，之后每次请求只写路径：`api.request(Config::new("/repos/moonbitlang/core"))`。分页参数交给 `with_params`，响应用 `json()` 显式解析。换一个 API 就 `create()` 一个新实例，两套配置互不干扰。仓库内 `src/cmd/main/main.mbt` 就是这个场景的可运行示例（用 `moon run src/cmd/main` 执行）。

**场景二：对接需鉴权的后端并上传文件。** 例如一个数据上报工具，服务端要求 Basic 认证且接口收 `multipart/form-data`。实例上 `with_auth` 一次配好凭据，请求侧 `with_data_from_form` 构造表单 —— 库会自动生成 boundary 并补上 `Content-Type`，表单里的 `name` / `filename` 按 WHATWG 规则转义。文件以字节数组传入，库不读磁盘，调用方对 I/O 保持完全控制。

**场景三：消费 SSE 事件流。** 例如接一个大模型的流式输出接口，或订阅服务端的日志推送。用 `Client::sse` 拿到 `SseStream`，按 `next_event()` 逐个事件读，不必自己处理"一次 TCP 读到的字节正好切在事件中间"的边界情况（解析器按字节缓冲，跨块安全）。事件里的 `id` / `retry` 会作为持久状态带出来，重连策略留在上层，由调用方决定退避与重订阅。

> 【手写】可以再加一个你自己最想解决的场景，或把上面某个场景换成你亲身遇到的真实需求（带上具体的服务名、接口形态、你觉得麻烦的地方）。三个场景是章程要求的底线，具体细节越真实越好。

## 四、交付范围与工程边界

### 已实现（截至 2026-09-24）

- 实例与配置合并：19 个 `with_*` 构建器、四种合并策略、方法缺省的三级回退
- 请求体四种形态：`with_data_from_str` / `with_data_from_json` / `with_data_from_form`（multipart，含文件）/ `with_data_from_urlencoded`，自动补 `Content-Type`
- 三个入口与三种读法：`request` / `stream` / `sse`，`text()` / `bytes()` / `json()`
- 自动重定向：`max_redirects` 默认 5 跳，含下一跳的方法 / body / 凭据 / `Host` 改写规则
- Basic 认证：`with_auth`，以 `Authorization` 头落线（`set_if_absent`，不覆盖用户显式设置的值）
- 错误模型：7 类 `ErrorCode` 映射 axios `ERR_*`，错误上挂完整响应或已读到的部分
- SSE 解析：独立包，按字节缓冲、跨块安全

### 本期交付（截至 9 月 30 日验收）

1. 代理支持（`proxy`）：CONNECT 隧道，代理凭据不泄漏给目标服务器 —— 实现中
2. 快捷方法：`get` / `post` / `put` / `delete` / `head` / `options` / `patch`，在 `request` 之上固定方法名与 body 位置
3. 取消 / 终止请求
4. 上传支持
5. 上传 / 下载进度回调
6. 请求 / 响应拦截器
7. `paramsSerializer`、`transformRequest`、`transformResponse` 三个 hook

### 明确不做（本版边界）

本版**不实现**：`withCredentials` 与 cookie 管理、SSE 自动重连、响应体自动解析。这些不做是刻意的设计选择，理由写在 README 的「暂不支持」与「与 axios 的其它差异」两节，且配置里不会出现对应字段 —— 避免「配置了但完全不生效」。

> 【手写】章程这一栏问的是"是否存在哪些内容是明确不做的"。上面已经列了，请你补一句你自己的取舍理由 —— 为什么这些能不做。这是展示工程判断力的地方。

### 后续扩展

连接池（当前每次请求新建连接）、cookie 复用。

## 五、实现路径与技术理解

**常见路径有三条**：(1) 直接包一层 `moonbitlang/async` 的 http，最快但把底层类型泄漏给使用者，换实现等于破坏 API；(2) 走 Sans-IO 路线，把 I/O 完全交给调用方（`gaato/http` 的选择），灵活但使用门槛高、开箱不可用；(3) 分层：底层 I/O 关在一个包里，上面建纯逻辑层。

**本项目选第三条。** 七个功能包按依赖方向构成 DAG：`transport` 是唯一接触 `moonbitlang/async` 的包，把底层类型挡在 `Transport` trait 与 `RawResponse` 契约之后（`MockTransport` 因此能在无网络下测试整条管线）；`url` / `config` 的序列化与合并规则是纯函数，可以脱离网络单独测试；门面类型（`Response` / `StreamResponse` / `SseStream` / `HttpError`）留在根包。已实现部分 7 个功能包 + 1 个示例包（`src/cmd/main`）、约 4900 行，197 个测试全部通过，其中 20 个测试文件覆盖字节级编码、合并策略、重定向改写规则与 SSE 解析边界。

> 【手写】完成实现需要哪些能力？你有没有一些独到的理解？
> 建议挑一个你真的想过的技术判断来写，例如：为什么 `Config.data` 做成私有字段（`Json::String` 的歧义、`Content-Type` 必须与 body 配套）、为什么响应体不自动解析（静态类型下"猜内容类型"的终点只能是让每个调用点自己 match）、为什么 `json()` 的失败抛 `ParseError` 而不是 `HttpError`。任选一个讲透，比铺开讲十个都有说服力。

## 六、工程现状

| 指标 | 数值 |
|---|---|
| 有效提交 | 14 |
| 包数 / 源码行数 | 7 个功能包 + 1 个示例包 / 约 4900 行 |
| 测试 | 197 个，全部通过 |
| 技术文档 | `docs/` 8 篇（架构、合并契约、请求管线、错误契约、传输层契约、SSE、请求体、重定向）+ 索引 |
| 许可证 | Apache-2.0（OSI 认可） |
| 持续集成 | 见仓库 `.github/workflows/` |

> 【手写】最后通读一遍整篇，把不像你自己说话的地方改掉。章程明确写着"明显包含 AI 套话或没有体现选手对选题有深刻认识的申报书会在审核阶段被驳回"，所以宁可句子粗糙一点，也要是你自己的判断。
