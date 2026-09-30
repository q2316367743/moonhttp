# 17 自研 HTTP 协议层（HTTP/1.x）：分支启动前的设计基准

**一句话**：为根治底层 `moonbitlang/async/http` 的结构性限制（封闭方法枚举见 `16-custom-http-methods.md`、
gzip 透明解压怪癖、`Client` opaque 导致连接池做不了、代理只支持 CONNECT），另起分支自研 HTTP/1.x 客户端栈，
按 RFC 分**协议层**与**实现层**两个包，为 2026-10 的连接池打地基。
**状态：第 1 期已落地（2026-09-29，分支 `feat/http-protocol`）**——协议层 `src/httpproto/`、
实现层 `src/httpconn/`、`Transport` 双实现并存、自定义方法与 gzip 自持随期交付；
实现细节与新旧栈对照见 `18-httpconn-transport.md`。七条口径照录如下，分支开发期间不得偏离。

## 已核实的可行性前提（动手前复核一遍）

| 前提 | 结论 |
|---|---|
| TCP | `@socket.Tcp::connect_to_host(host, port~)` → 实现 `@io.Reader`/`@io.Writer` |
| TLS | `@tls.Tls::client(任意读写流, verify?/host?/sni?/trust?)` 可包任意流 → **CONNECT/SOCKS 隧道上做 HTTPS 成立**；`TrustedRoot`（NoVerification/SystemRoot/CustomPemFile）与现有 `trust~` 一一对应 |
| HTTP/2 | **gated**：`@tls` 公开 API 与 openssl 适配层均未暴露 ALPN（2026-09-29 全文检索零命中），h2 的 TLS 协商走不通 → 见口径第 1 条 |
| SOCKS 代理 | 现有栈结构性做不到（代理参数只收 `@http.Client`、隧道只有 CONNECT）；自研栈里是纯增量小模块，见下 |
| 传输层可替换 | `Client::new(config~, transport~)` 早已支持注入，新实现与 `AsyncHttpTransport` 双实现并存、灰度切换，超时 / 取消 / 进度 / 重定向 / 拦截器零改动 |

## 七条已定口径（2026-09-29 owner 拍板，分支启动后不得偏离）

1. **只实现 HTTP/1.0 与 HTTP/1.1**；HTTP/2 等官方 `@tls` 补齐 ALPN 后再立项（h2c 先验模式不值得做，主流服务器不开放）。
   1.0 在 1.1 分帧层上加兼容分支即可（默认 close、`Host` 可选、不收发 chunked）。
2. **http 与 https 都实现**：https = `Tls::client` 罩在 Tcp（或隧道流）上，SNI 用目标 host，`verify`/`trust` 透传现有配置。
3. **代理补 SOCKS**：只做 **SOCKS5**（RFC 1928 + RFC 1929 用户名密码，4/4a 有需要再说）；握手三步
   （问候 → 可选认证 → CONNECT 请求），之后流即裸管道；**远程 DNS 默认开启**（ATYP 走域名，解析交给代理，
   与 CONNECT 行为一致、避免本地 DNS 泄漏）；CONNECT 代理语义不变（`docs/09-proxy.md` 为准，凭据仍只落隧道握手）。
   握手字节序列的解析与生成是**纯逻辑**，放协议层包做同步测试，实现层只做 I/O 驱动。
4. **gzip / keep-alive 等策略全由本库自持**：
   - gzip：`Accept-Encoding` 声明策略、两条路径（缓冲内存解压已有 `transport/decode.mbt`；流式用 `@gzip` 流式解码器包装）
     统一由我们做，摘头口径沿用 `15-response-compression.md` 的「谁解压谁声明」——底层「补了 Accept-Encoding 才透明解压」
     的怪癖与「`Content-Length` 被顺手删掉」随之消失；不认识的编码原样交出。
   - keep-alive：连接状态机 `Connecting → Idle → Busy → Draining → Closed`；**响应体未消费完不回池；
     取消 = 毒化连接**（协程被打断后无法知道字节流停在哪，回池会串响应）；池本身是第 2 期，契约第 1 期就定死。
   - HTTP/1.0 连接默认 `Connection: close`；一次性请求期发 `close`，池上线后按需 keep-alive。
5. **子包高内聚低耦合**：延续现有 DAG 纪律——协议层是纯逻辑叶子包（同步测试），实现层只依赖协议层与底层 async。
6. **自定义方法的测试靶子由 owner 提供**（WebDAV 客户端实测）；协议层分帧的正确性仍由纯逻辑同步测试自证
   （「测试比代码多」的那部分成本在这里，不在真实网络靶子上）。
7. **按 RFC 分两包：协议层 + 实现层**（净室实现，依据 RFC 9110 / 9112 / 1928 / 1929，不通读上游源码）：
   - **协议层**（纯逻辑，包名占位 `httpproto`）：请求行 / 状态行、头解析（含 obs-fold 与**协议层 multimap**——
     HTTP 允许重复头如 `Set-Cookie`，门面仍是单值 `Headers`；压平规则后来定为「同名取最后一个值、
     `Set-Cookie` 全量另走 `RawResponse.set_cookies` 多值出口」，`docs/05` 挂起的「响应 cookie」随之在
     `docs/19-cookies.md` 落地）、
     chunked 编解码（解码含 trailer / extension / CRLF 跨块，编码为下一期流式上传预留）、content-length、
     close-delimited、无体规则（HEAD/204/304）、SOCKS5 握手字节。
   - **实现层**（async，包名占位 `httpconn`）：`Connection` 三态建连（TCP / TLS / CONNECT 或 SOCKS 隧道+TLS）、
     请求写入（一次性请求体一律 `Content-Length`）、响应读取、生命周期状态机，并实现 `transport` 包的 `Transport` trait
     （依赖方向：`httpconn → transport`（拿 trait）+ `httpconn → httpproto`，不成环）；旧 `AsyncHttpTransport` 保留为回退。

## 分期

| 期 | 交付 | 说明 |
|---|---|---|
| 第 1 期 | 协议层分帧 + 一次性连接的 HTTP/1.1 传输实现（`Transport` 双实现并存，构造注入切换） | 自定义方法在自研路径**第一天可用**（docs/16 的解锁清单随之作废一半——不再需要等上游）；gzip 语义统一；SOCKS5 可提前在此期落地（它不依赖池） |
| 第 2 期 | **连接池**（2026-10） | 按 `(scheme, host, port, tls, proxy)` 分桶、每 host 上限、空闲超时、取用时坏连接重试一次；CONNECT / SOCKS 隧道均入池 |
| 第 3 期（gated） | HTTP/2 | 前置：上游 `@tls` 补 ALPN（比自定义方法小得多的上游诉求，openssl 原生支持只是没接线）；HPACK（RFC 7541，自带官方测试向量）+ 多路复用 + 流控是独立大活，不与池抢人力 |

## 待决问题（分支启动前过一遍）

- `Expect: 100-continue` 做不做（建议缓）；响应 trailer 要不要透出（h1 场景建议先丢弃）。
- `deflate` / `br`：`@gzip` 之外编解码器生态是空的，建议砍（沿用「不认识的编码原样交出」口径）。
- 协议层 multimap → 门面单值 `Headers` 的压平规则（**已落地**：取最后一个值；`Set-Cookie` 走
  `RawResponse.set_cookies` 多值出口，见 `19-cookies.md`）。
- 官方 `AsyncHttpTransport` 保留多久（建议长期保留为回退，逃生门不花钱）。
- 包名定名（`httpproto` / `httpconn` 为占位）、分支名（建议 `feat/http-protocol`）。

## 启动后的文档联动清单

`docs/05-transport.md`（能力表加自研实现一行）、`docs/09-proxy.md`（SOCKS5 一节 + 撤「不做 SOCKS」）、
`docs/15-response-compression.md`（解压统一后重写「两条路径」论）、`docs/16-custom-http-methods.md`
（自研路径解锁自定义方法，上游 issue 降级为「让官方实现也受益」）、`README.mbt.md`（暂不支持清单逐条撤）。
