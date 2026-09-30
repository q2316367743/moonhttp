# 18 自研 HTTP/1.x 传输层（httpproto + httpconn）：第 1 期实现与默认切换

**一句话**：`docs/17` 规划的第 1 期已落地——按 RFC 净室实现的 HTTP/1.0/1.1 客户端栈，
分**协议层**（`src/httpproto/`，纯逻辑）与**实现层**（`src/httpconn/`，async I/O 驱动）两个包，
实现 `Transport` trait；**2026-09-30 起它是缺省传输实现，旧的 `AsyncHttpTransport`
（基于 `moonbitlang/async/http`）已整体删除**——自定义方法（WebDAV 的 `PROPFIND` 等）
在默认路径可用（`docs/16` 的解锁清单随之完成），对底层 HTTP 库的生产依赖归零，
gzip 的声明与解压全由本库自持。

## 用法

传输层是注入切换的，客户端其余能力（拦截器、重定向、取消、进度……）零改动：

```moonbit nocheck
// 缺省传输就是自研栈，什么都不用做；自定义方法直接构造 Method::Other
let propfind = @moonhttp.Config::new("https://dav.example.com/cal/")
  .with_method(@moonhttp.Method::Other("PROPFIND"))
  .with_header("Depth", "0")
let response = client.request(propfind)
// transport~ 仍可注入（测试注入 MockTransport，或接自己的实现）
```

`Client::new` 的缺省 transport 是 `@httpconn.HttpConnTransport::new()`（根包生产依赖
`httpconn`）；旧栈不是「可选回退」而是**已删除**——注入切换的口径保留给 `MockTransport`
与自定义实现。

## 两个包的边界

| 包 | 职责 | 依赖 |
|---|---|---|
| `httpproto` | 请求行/状态行、头块解析（obs-fold、multimap）、分帧判定、chunked 增量解码、token 校验、头块渲染。全部纯逻辑，同步测试 | 只依赖 core |
| `httpconn` | 拨号（TCP/TLS/CONNECT 隧道）、请求写入、响应头读取、分帧响应体、gzip 自持、`Transport` 实现 | transport（拿 trait）+ httpproto + async 运行时 |

依赖方向 `httpconn → transport + httpproto` 不成环；旧栈删除后，对 `moonbitlang/async/http`
的依赖为 0（测试里只剩 `@http.Server` 当本机服务器夹具），与 async HTTP 库相关的
网络交互集中在 `httpconn` 一处；根包为缺省传输生产依赖 `httpconn`。

## 分帧判定（RFC 9112 §6.3，判定顺序不可交换）

1. **无体规则最先**：HEAD 请求的任何响应、1xx、204、304 → 无体（头上写了 `Content-Length` 也不认）；
2. **TE 优先于 CL**：`Transfer-Encoding` 存在时忽略 `Content-Length`（两者并存是中间盒改写过的形状）；
   TE 摊平后的编码序列必须恰好是 `chunked`——最后的编码不是 chunked、或带了其它编码，显式 `Malformed`；
3. **多条 `Content-Length` 必须全部一致**（含逗号分隔写法），不一致即走私形状，`Malformed`；
4. 都没有 → **读到连接关闭为止**（HTTP/1.0 不写 CL 是常态）。

chunked 解码是增量状态机（`httpproto/chunked.mbt`）：CRLF、行、数据都允许跨任意字节切点；
trailer 解析后**丢弃**（`docs/17` 待决问题的口径），chunk 扩展忽略；终止 chunk 之前连接关闭
显式报 `Malformed`（把半截数据当完整响应比报错更糟）。

## gzip：谁解压谁声明（docs/15 的延伸）

| 请求里的 `Accept-Encoding` | 谁写的 | 响应 gzip 时谁解 | 摘头 |
|---|---|---|---|
| 没有 | httpconn 自补 `gzip` | httpconn 流式解压（`@gzip.Decoder` 包分帧 reader） | `Content-Encoding` + `Content-Length` 一起摘，`total` 归 `None` |
| `gzip, identity` | client 层（缓冲路径） | 不解——原样交字节，client 层 `decode_response_body` 内存解压 | 不动（旧栈同） |
| 用户自己设的 | 用户 | 不解 | 不动（流式交出的字节自描述） |
| `identity` | client 层（`decompress: false`） | 没人解 | 不动 |

（旧栈的「补了 `Accept-Encoding` 才透明解压」怪癖随旧栈删除——判定锚点就是
自己头里的声明。）

## 与已删除旧栈的行为差异（历史记录）

旧栈 `AsyncHttpTransport`（基于 `moonbitlang/async/http`）已于 2026-09-30 删除；
下表是从它切过来时可观察的行为差异，留作排查历史问题的对照：

| 维度 | 旧栈（已删除） | 现行（`HttpConnTransport`） |
|---|---|---|
| 自定义方法 | 建连前 `Unsupported`（底层枚举封闭） | 原样发送（token 校验在建连前） |
| 协议 | 底层库决定 | HTTP/1.0/1.1（h2 gated：`@tls` 无 ALPN） |
| gzip | 缓冲库解 + 流式底层透明解 | 缓冲库解 + 流式自己解（上表） |
| 请求体线上形状 | 无体发 `Content-Length: 0` 或 chunked | 一律 `Content-Length`（无体发 0） |
| 连接 | 每请求一条（`@http.Client` 四步式） | 每请求一条 + `Connection: close`（池是第 2 期） |
| TLS 校验 | 底层默认 | `Tls::client(host=…)` 默认校验 + SNI=目标 host |
| 代理 | CONNECT（底层实现） | CONNECT（自己实现，凭据只落隧道请求）；SOCKS5 见下 |
| 错误分类 | `TransportError` 五变体 | 同一套（`with_abort_scope` 也复用 transport 的） |
| Set-Cookie | 底层单独解析，不出现在 headers | 原样保留在 headers，同时进 `set_cookies` 多值出口 |

## 有意的赌注与它的哨兵

`Connection` / 分帧 body 都在 `moonbitlang/async` 包外实现 `@io.Reader`
（pushback 用公开构造器 `ReaderBuffer::new()`；trait 的两个必需方法未标 `#internal`）。
该类型本身被上游标了「内部用途」，两个包的 `moon.pkg` 里 `warnings = "-alert_internal"`
是**有意关闭**（上游 `core/debug/moon.pkg` 有同款先例）。`stream_wire_test.mbt`
（transport 包）是这条赌注的哨兵：上游若收紧，它第一个失败。
届时退路：改用 `@io.MemoryReader(生产者闭包)` 泵送桥接（协议层分帧逻辑不变，
只换「谁把字节递给 Reader」），gzip Decoder 照样可包。

## 默认切换时修掉的真实缺陷（2026-09-30，真连接读路径）

切换默认实现让全部端到端用例第一次整体压在 httpconn 上，暴露并修复了三个只有
真连接才踩得到的缺陷，各有回归用例钉在 `src/httpconn/stream_real_test.mbt`：

- **头后残留泄漏**：读头的「多读」会把原始线字节（含 chunked 帧头）留进连接缓冲，
  BodyReader 曾与连接共用缓冲，而默认读方法「缓冲有字节就直接交出、不再过
  `_direct_read`」，帧原样漏进响应体。修复：BodyReader 自持输出缓冲
  （`body_reader.mbt` 的所有权注释）。
- **chunked 读取等满**：`_direct_read` 的 chunked 分支曾循环拉到填满 `max_len`，
  违反 `read_some`「数据一到尽快返回」的契约——SSE 的下一个事件被堵在一次读取里，
  取消也因此失去落点。修复：一有解码产出就返回。
- **隧道错误被二次包装**：`send_head` 的 catch-all 把 dial 辅助函数抛的
  `TransportError` 又包了一层，「代理拒绝建立隧道：HTTP 407 …」被冲成一句类型名。
  修复：传输层自己的错误原样透传。

## 本期未做（按 docs/17 分期）

- **连接池**（第 2 期，2026-10）：契约已在 `docs/17` 定死——体未消费完不回池、取消=毒化。
- **SOCKS5**：`parse_target` 已认识 `socks5` scheme（代理地址解析用），
  作为请求目标/代理都会显式报 `Unsupported`；握手字节（RFC 1928/1929）属协议层，
  下一个提交补齐（远程 DNS 默认开，`docs/17` 口径 3）。
- chunked **编码**（随流式上传）、`Expect: 100-continue`（缓）、响应 trailer 透出（丢弃）、
  `deflate`/`br`（不认识的原样交出）。

## 改动时的同步清单

- 改分帧判定 / chunked：先改 `httpproto` 的纯逻辑 + 同步测试，`httpconn` 只跟驱动；
  同步本文的判定表。
- 改 gzip 规则：同步 `15-response-compression.md`（两条路径的归属见本文的表）。
- 改拨号 / 隧道：`09-proxy.md` 是 CONNECT 语义的契约文档；SOCKS5 落地时撤「占位」两处
  （本文与 `README.mbt.md` 的暂不支持清单）。
- 新增头装配规则：`httpconn/request_write.mbt` 的 `build_request_headers` 是唯一实现。
