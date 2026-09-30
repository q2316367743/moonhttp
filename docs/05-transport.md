# 05 传输层契约

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/transport/transport.mbt` | `Transport` trait、`PreparedRequest`、`RawResponse`、`TransportError` |
| `src/transport/stream.mbt` | `ResponseBody`：响应体流（真实连接 / 内存体两种来源），按块读的部分 |
| `src/transport/stream_lifecycle.mbt` | `ResponseBody` 的构造与释放（`from_bytes` / `open` / `rewind` / `close`），含取消登记 |
| `src/transport/stream_all.mbt` | `ResponseBody` 的「读全量」三件套（`drain_into` / `read_all_partial` / `read_all`）与下载进度的逐块报告 |
| `src/transport/async_http.mbt` | 真实实现（唯一对接 `moonbitlang/async` 的文件），含上传进度的分块写、把底层已解掉的 `Content-Encoding` 摘掉 |
| `src/transport/cookies.mbt` | 旧栈的 Set-Cookie 出口：把底层 `@http.Response::cookies` 序列化还原成头值喂给 `RawResponse::set_cookies`（保真度说明与自研栈的原文收集对照见 `19-cookies.md`） |
| `src/transport/decode.mbt` | `Content-Encoding` 的解码工具：`decode_gzip`（整份字节的内存解压）与 `declares_gzip`（认定 gzip 的唯一判据），见 `15-response-compression.md` |
| `src/transport/mock.mbt` | 测试用实现：记录请求、按队列返回响应、可注入失败 |
| `src/transport/transport_test.mbt` | 传输层自身的用例（含不依赖外网的真实实现用例） |
| `src/transport/stream_test.mbt` | 响应体流的读语义 + 本机 server 的真实流式读取用例 |

## 契约

```moonbit
pub(open) trait Transport {
  async fn send(Self, PreparedRequest) -> RawResponse raise TransportError
}
```

`PreparedRequest` 是**已经做完所有配置语义加工**的请求，字段含义：

| 字段 | 含义 |
|---|---|
| `http_method` | 最终方法（缺省回退已完成） |
| `url` | 完整地址，已含 `base_url` 拼接结果与序列化后的 query |
| `headers` | 已按 `common` < 按方法 < 请求级平铺 拍平、且已补过 `Content-Type` / `Authorization` 的最终头集合 |
| `body` | 请求体字节；`None` 表示不带 body |
| `timeout` | 超时毫秒数；`None` 或 `<= 0` 表示不限时 |
| `proxy` | 代理服务器（`ProxyEndpoint`：`url` + `authorization`）；`None` 表示直连。契约见 `09-proxy.md` |
| `on_upload_progress` | 上传进度回调；`None` 表示不报告。**由传输实现负责调用**（内置实现按 64 KiB 分块写、逐块回调；`MockTransport` 不调用）。语义见 `10-progress.md` |
| `signal` | 取消信号；`None` 表示这次请求不可取消。**由传输实现负责尊重它**（内置实现在进入每跳发送时先查 `aborted()`，再把中断手段登记到它上面；`MockTransport` 不理会——它同步返回、没有挂起点可中断）。语义见 `12-cancellation.md` |

`RawResponse` 是**纯传输结果**，刻意不叫 `Response`（上层的 `Response` 还要承担响应体解码与状态码校验）：

| 字段 | 含义 |
|---|---|
| `status` | HTTP 状态码 |
| `status_text` | 原因短语 |
| `headers` | 响应头（本项目自己的 `Headers`，大小写不敏感） |
| `body` | **响应体流**（`ResponseBody`），不是字节 |
| `set_cookies` | `Set-Cookie` 的**全部值**（保序）。多值头（RFC 9110 §5.2 不许合并）不能走单值的 `headers`；cookie jar 自动维护吃的就是这份列表，见 `19-cookies.md` |

`TransportError` 有五类：`Timeout` / `Network(String)` / `Unsupported(String)` / `Malformed(String)` / `Cancelled(String?)`。
前四类覆盖「网络世界里可能出什么事」加上「响应本身读不出来」——`Malformed` 表示响应体与它声称的 `Content-Encoding`
不符（目前只有 `decode_gzip` 抛它，上层报 `ERR_BAD_RESPONSE`，见 `15-response-compression.md`）。
`Cancelled` 是「调用方自己喊了停」——它**带着取消理由**（`signal.reason()`，可能为 `None`）随错误一起上来，
因为信号不在配置里、上层没有别的地方能找到它；措辞仍由根包一处决定（默认文案「请求已取消」）。
它也不该与网络故障混为一谈。分类的用途见 `04-errors.md`。

`headers` 里**没有 `Content-Encoding` 就等于「交出去的字节是实体字节」**：内置实现在底层替它解压过 gzip 时会把那句
已经失效的 `Content-Encoding` 摘掉；自定义实现要么自己交付解码后的字节、要么把声称编码的头留着（两者一致即可），
见 `15-response-compression.md`。

### 为什么 `body` 是流

`send` 返回时只保证「状态行 + 响应头已经到手」，响应体按需读。底层原语只保留最弱的能力，一次性读全是**上层**的组合结果（`Client::request` 就是 `read_all()` 之后按 `response_encoding` 解码）。这样 chunked / SSE 这类「边到边读」的协议才有落点——SSE 的全部要求就是「先看状态码与 `Content-Type`，再一段段取数据」。

### `ResponseBody` 契约

```moonbit
pub fn ResponseBody::from_bytes(Bytes) -> ResponseBody   // 内存体：Mock 与自定义实现用
pub fn ResponseBody::open_wire(&@io.Reader, close : () -> Unit, timeout~, total~, signal~) -> ResponseBody
                                                         // 连接流：自研传输（httpconn）用，close 负责释放连接
pub async fn ResponseBody::read_some(Self, max_len? : Int) -> Bytes? raise TransportError
pub async fn ResponseBody::read_until(Self, sep : String) -> String? raise TransportError
pub async fn ResponseBody::read_all(Self, on_progress? : ProgressCallback) -> Bytes raise TransportError
pub async fn ResponseBody::read_all_partial(Self, on_progress? : ProgressCallback) -> (Bytes, TransportError?) noraise
pub fn ResponseBody::close(Self) -> Unit
```

`on_progress` 是下载进度的报告钩子（`None` 表示不报告），只有两个「读全量」的方法有它：按块读的 `read_some` / `read_until` 不报告，那条路由调用方自己累加。报告粒度、`total` 从哪来、回调为什么是 `noraise` 见 `10-progress.md`。

三种来源（旧栈连接、自研栈连接流、内存字节）的语义**完全一致**，对齐 `@io.Reader`，Mock 才能真实代表网络侧：

- `read_some` 到 EOF 返回 `None`；返回的块大小不保证（取决于对端一次发了多少）；
- `read_until` 消费掉分隔符且不返回它；EOF 时把剩余内容当作最后一段返回，再读一次才是 `None`；
- `read_all` 读完剩余内容，空体返回空字节串；
- **`read_all_partial` 与 `read_all` 读到的字节相同，区别只在失败时**：失败不当异常抛出，而是返回 `(已读到的部分, Some(错误))`——网络在读到一半断掉时，已经到手的字节往往正是现场（错误响应的正文、下载进度），上层要把它们挂到错误上（见 `04-errors.md`）。`read_all` 就是它的「失败即抛」包装；
- **读到 EOF 会自动关闭底层连接**——本项目不复用连接，早关没有代价；`read_all_partial` 在失败时同样关闭（两种结局都关）；
- `close()` 幂等。没有析构器，**拿到流后不读完也不 `close()` 会漏一条连接**；
- 任何读取失败都会先关闭流再抛 `TransportError`：失败之后连接状态已不可信，调用方不该继续读。

**流的字节里没有「内容编码」这一层**：`ResponseBody` 交出去的永远是实体字节（`Content-Encoding` 已经被负责解码的一方消掉）。
缓冲路径是上层读完自己解；流式路径在自研传输（httpconn）里由本库声明并解压（谁解压谁声明）、在旧栈里由底层透明懒解压——口径、谁声明压缩、响应头怎么跟着变，
见 `15-response-compression.md` 与 `18-httpconn-transport.md`。自定义传输实现若要交出 gzip 字节，就必须把 `Content-Encoding` 一起交出去（让头与体说同一件事）。

`read_all_partial` 的声明带 `noraise`：MoonBit 里 async 函数省略错误类型**不等于**不抛错（省略等于开放错误类型），要表达「不抛」必须显式写 `noraise`。

**不要用 `read_until("\n\n")` 切 SSE 事件。** CRLF 流上事件边界的字节是 `0D 0A 0D 0A`，里面没有连续两个 `0A`，这个分隔符永远匹配不到：内存体上表现为「整段原样返回」，真实连接上更糟——EOF 不会来，于是会一直等到连接关闭（不限时的 SSE 配置下就是永远等下去）。事件切分要按规范认 CRLF / LF / CR 三种行尾，落在**根包**的 `SseParser` 里，不在传输层，见 `06-sse.md`；`src/transport/stream_test.mbt` 有一条用例专门钉住这个坑。

`ResponseBody` 刻意**不**实现 `@io.Reader`：那要实现 `_get_internal_buffer` / `_direct_read` 这两个标注「仅内部实现」的方法（它们要命名 async 包内部的 `ReaderBuffer`，跨模块做不到），也会把「底层换 Reader 实现」这件事漏进本模块。只暴露上面五个方法。
gzip 解压因此也不在流上做：缓冲路径读完再解（`decode_gzip` 借一个内存管道把字节喂给 `@gzip.Decoder`），流式的懒解压交给底层，见 `15-response-compression.md`。

### 超时语义

`PreparedRequest::timeout` 分两段生效：

| 阶段 | 受谁约束 |
|---|---|
| 建连 + 发请求头 + 写 body + 等响应头 | `@async.with_timeout` 整体包住 |
| 响应体读取 | `ResponseBody` 按 `timeout` 包住，口径随读法不同（见下表） |

响应体读取的口径分两种，区别在「一次」指的是什么：

| 读取方法 | 一次 = | 含义 |
|---|---|---|
| `read_some` / `read_until` | 一次调用 | 等一次数据算一次：数据一直在流动就不会超时，卡住不动的间隔超过 `timeout` 才失败（SSE 正是靠这个语义长连） |
| `read_all` / `read_all_partial` | 整段读完 | 从开始读到 EOF 共用一个时限：大文件下载不会因为「一直在慢慢传」而无限期拖下去 |

也就是说超时从「整条请求的总时限」细化成了「响应头阶段总时限 + 响应体读取的等待上限」。这么切的原因：

- 非流式路径不能因为改成流式就丢掉「响应体下载慢也会超时」的原有行为；
- SSE 这类长连「长时间没有数据是正常的」，必须完全不限时。内置默认值就是不限时（`defaults()` 给的是 `Some(0)`，`<= 0` 一律视为不限时），所以在默认实例上直接 `stream` 就能长连；显式设过 `timeout` 的实例要用 `with_timeout(0)` 关掉。

读取阶段超时同样抛 `TransportError::Timeout`，上层映射成 `ErrorCode::Timeout`。中途超时前已经读到的字节不会丢：`read_all_partial` 把它们交出来，上层挂到错误上（见 `04-errors.md`）。

### 取消语义

`PreparedRequest::signal` 是「这次请求可以被谁打断」的那个观察口。机制与对外语义在 `12-cancellation.md`，传输层的责任只有三条：

| 阶段 | 传输层做什么 |
|---|---|
| **进入**每一跳的发送作用域 | 先查一遍 `aborted()`：已经取消就一步都不跑，直接抛 `TransportError::Cancelled`——挡住「取消落在两段 I/O 之间」（重定向的两跳之间就是一例）；否则把这一跳放进 `with_abort_scope`（`src/transport/abort.mbt`）：信号取消 → 子任务被 `Task::cancel` → 挂起中的 socket 动作立刻中断 |
| 响应体每次读取 | 同一条取消作用域（在 `read_or_fail` 里），所以按块读、读全量、SSE 都能被中断；读入口另有一次 `aborted_failure` 检查：报 `TransportError::Cancelled` 而**不是**退化成 EOF（`Closed => None` 会被上层当成「对端正常结束」） |
| 取消已经发生之后 | `ResponseBody` 挂在信号上的那条登记会 `close()` 连接——调用方取消之后不再读也不会漏连接（`close` 幂等，注销发生在 `close()` 里）；`ResponseBody::open` 进来时信号已取消则当场关闭这条连接 |

四条必须知道的口径：

- **取消不是网络失败**：它在协程模型里是信号，`catch` 抓不住（`defer` / `errdefer` 会跑）。所以由 `with_abort_scope` 在 `task.wait()` 处把 `TaskCancelled` 翻译成 `TransportError::Cancelled`——指望上层 `catch` 是抓不到的。传输层也不生成取消文案：理由随 `Cancelled(reason)` 一起上来（信号不在配置里），措辞由上层一处决定。
- **取消的落点是挂起点**：一段纯计算（或回调里的长循环）不会被打断，取消在下一个挂起点生效。取消与超时互不吞并，先到的那个说了算（取消的作用域在超时之外）。
- **登记不补触发**：信号上的登记在已取消时既不触发也不保留（与 JS 的 `addEventListener` 一致），所以**每个可取消 I/O 的入口都要自己先查 `aborted()`**——自定义实现同理。
- **自定义实现的义务**：尊重 `signal` 是可选但推荐的。`MockTransport` 不理会它（同步返回、没有挂起点可中断），此时「已取消的信号让请求失败」仍由上层进入管线时的预检查兜住，只是「打断进行中的请求」这一条不成立。

## 写一个自定义实现

```moonbit
pub impl Transport for MyTransport with fn send(self, request) {
  let body = match request.body {
    Some(bytes) => bytes
    None => b""
  }
  {
    status: 200,
    status_text: "OK",
    headers: Headers::new().set("Content-Type", "application/json"),
    // 响应体是流：手里已经有完整字节时用 from_bytes 包一层
    body: ResponseBody::from_bytes(body),
  }
}
```

### 注意事项

1. **实现里的方法写 `fn` 而不是 `async fn`**。异步性是 trait 声明的一部分，`impl` 侧不重复标注；写成 `async fn` 会报语法错误。这与 `moonbitlang/async` 自身的写法一致（它的 `pub impl @io.Reader for Client with fn _direct_read(...)` 对应的 trait 方法就是 `async fn`）。
2. **`impl` 前要写 `pub`**，否则外部包看不到这个实现，无法把它当作 `&Transport` 使用。
3. **还要补一条 `pub extend`**：`pub extend MyTransport with Transport::{send}`，否则会收到「trait impl 隐式挂成常规方法」的废弃告警。
4. `&Transport` 特质对象的异步方法可以直接调用（底层实现是「结构体里存 `&Trait` 字段 + 异步调用」，`moonbitlang/async` 的 `parser.mbt` 就是这么写的）。

## `AsyncHttpTransport` 的实现细节

真实实现手动走底层 `@http.Client` 的四步：

```
@http.Client::Client(root)  →  Client::request(meth, path)  →  Client::write(body)  →  Client::end_request() → 响应头
```

`end_request()` 返回时**响应体还在连接上**，实现把这条连接的所有权交给 `ResponseBody`，所以传输层不读 body。两个没选的方案与原因：

- `@http.request(uri, method, headers, body)`：便捷，但内部 `client.read_all()` 把整个响应体读光，SSE 就没有落点了——这正是本次改造要解决的问题；
- `@http.get_stream(uri, ...)`：返回 `(Response, Client)` 正合用，但只覆盖 GET（`post_stream` / `put_stream` 只返回写入口，拿不到响应头）。

第三步的 `write` 由 `write_body` 承担：没有上传进度回调时是一次 `client.write(body)`（与改造前完全一致），有回调时按 `UPLOAD_CHUNK_SIZE` 分块写、每块 `flush` 后报一次进度。分块不改变线上行为——底层不传 `Content-Length` 时请求体本来就是 `Transfer-Encoding: chunked`，它的发送缓冲只有 1 KiB，整块 `write` 在底层早已被切成许多 chunk；这里只是换个切法并让「报告了 = 已经交给内核」成立。同时 `send` 从响应头解析出 `Content-Length` 交给 `ResponseBody::open`，作为下载进度的 `total`（取不到就是 `None`）。

配套的四处适配：

1. **地址切分**（`split_url`）：底层 `Client::Client(uri)` 要求 uri 的 path 恰好是 `/`（否则抛 `InvalidFormat`），路径必须留给 `Client::request(meth, path)`。切法镜像底层私有的 `resolve_url`：按 `://` 分出协议，取之后第一个 `/` 之前的部分作为 host、其余作为 path+query。相对地址与非 http/https 协议抛 `TransportError::Unsupported`——同一类输入以前走 `@http.request` 时会被归到 `Network`，现在分类更准（`Unsupported` 的定义就是「请求还没发出去就失败了」）。
2. **枚举映射**：本项目的 `Method` 与底层的 `RequestMethod` 一一对应（`to_request_method`）。上层不认识底层类型，所以映射写在这里。注意两边都是九个标准方法的封闭枚举（上游 main 分支同样），WebDAV 等扩展方法本期发不出去——证据、被排除的绕行路线与解锁方案见 `16-custom-http-methods.md`。
3. **头的容器转换**：底层要求 `Map[CaseInsensitiveString, String]`（`to_http_headers` / `from_http_headers`）。两边都是大小写不敏感的容器，转换只搬类型不改语义。头与便捷函数一样在 `Client::Client` 建连时一次性交出，body 单独 `write`，语义与改造前一致。
4. **超时与错误收敛**：见上文「超时语义」；底层 `TimeoutError` → `TransportError::Timeout`，其余错误统一归 `Network` 并保留原始错误文本。建连之后任何失败都靠 `errdefer client.close()` 关连接，不留半开连接。
5. **代理**（`request.proxy` 非空时）：在同一个 `attempt` 里先建一个**干净的代理客户端**（`open_proxy`，凭据以持久头的形式交给它）再传给 `Client::Client(root, proxy?)`——放在这里是为了让 CONNECT 握手也落进 `timeout`。底层的代理客户端**所有权会被接管**，所以每次请求都得新建、不能缓存。CONNECT 非 2xx 时底层抛 `ProxyError`，这里翻译成 `Network("代理拒绝建立隧道：HTTP <状态码> <原因短语>")`（单独一条 catch 分支，在通用兜底之前）。细节见 `09-proxy.md`。

### 尚未处理的能力（改动时的落点）

| 能力 | 现状 | 可能的实现方式 |
|---|---|---|
| 连接复用 | 每次请求新建连接 | 按 host 缓存 `@http.Client`；注意本项目不回传连接池状态给上层，缓存要自己做失效处理 |
| 请求体流式上传 | 不支持（`PreparedRequest::body` 是完整字节） | 需要 `ResponseBody` 的对偶：一个挂在 `@http.Client` 上的可写流，`write` 完再 `end_request()`。README 的「暂不支持」里标了下一期 |
| 上传进度 | **已支持**（`PreparedRequest::on_upload_progress`）：按 64 KiB 分块写 + 每块 `flush` 后回调。分块不改变线上格式——请求体本来就是 chunked | 粒度见 `async_http.mbt` 的 `UPLOAD_CHUNK_SIZE`；契约见 `10-progress.md` |
| 下载进度 | **已支持**（`ResponseBody` 的 `read_all*` 带 `on_progress`），只由「库读全量」触发 | 见 `10-progress.md` |
| 代理 | 已支持（`PreparedRequest::proxy`） | 底层 `Client::Client(uri, proxy~)` 的 CONNECT 隧道；凭据落在代理客户端自己的持久头上。契约与注意事项见 `09-proxy.md` |
| TLS 校验开关 | 固定为默认（校验） | `Client::Client(trust~ / verify~)` |
| 自定义请求方法 | **已支持**（`Method::Other(String)`，自研传输 `HttpConnTransport` 原样发送；旧栈在建连前报 `ERR_NOT_SUPPORTED`） | 自研路径见 `18-httpconn-transport.md`；旧栈受底层封闭枚举所限（证据与上游 issue 见 `16-custom-http-methods.md`） |
| 响应 cookie | **已支持**（`RawResponse.set_cookies` 多值出口 + `Client::new(cookie_jar~)` 的自动维护）：自研栈原文收集、旧栈从底层 `Response::cookies` 序列化还原 | 契约与实现见 `19-cookies.md` |
| SSE 事件解析 | 已实现，但**不在本模块** | 传输层只交出字节流；事件边界与 `event:` / `data:` 字段语义在 `sse` 包（`SseParser`），接到 HTTP 上的入口是根包的 `Client::sse` / `SseStream`，见 `06-sse.md`。分层的意义是「字节怎么来」与「字节怎么解」各自独立演进：换成别的字节来源（WebSocket、文件）也能复用同一个解析器 |

改动这些能力时请只动 `src/transport/` 与 `src/httpconn/`——它们是本模块唯二对接 `moonbitlang/async` 的包（`src/transport/*.mbt` 都可以改，不限于 `async_http.mbt`）。`PreparedRequest` 的字段语义不要动（加字段是加能力，比如 `proxy`；改已有字段的含义不是）；`PreparedRequest` / `RawResponse` 的结构变化（例如本次 `body` 由字节改成流、`proxy` 字段的加入）必须同步本节与 `03-request-pipeline.md`，因为它们出现在公开签名里。

## `MockTransport` 的用法

```moonbit
let mock = @transport.MockTransport::new(response)          // 始终返回该响应
let mock = @transport.MockTransport::from_responses(queue)  // 按队列返回，用完后复用最后一个
let mock = @transport.MockTransport::failing(error)         // 总是失败
let transport : &@transport.Transport = mock

// 请求发生后断言发出去的内容
let sent = mock.last_request().unwrap()
println(sent.url)
println(sent.headers.to_string())
```

队列空了之后复用最后一个响应，是为了让「同一个响应要被请求多次」的用例不必重复塞响应；完全没有配置响应时抛 `TransportError::Unsupported` 而不是返回空响应——静默的成功会让测试变得不可信。

**响应体要用 `ResponseBody::from_bytes` 构造。** 响应体是流，Mock 每服务一次都会 `rewind()` 出一份「从头开始读」的副本：否则「复用最后一个响应」会让第二次请求读到空 body，用例会静默地变假。`rewind` 只对内存体成立，把真实连接上的响应体配给 Mock 会抛 `TransportError::Unsupported`。

内存体**永远读得完**，所以「读到一半失败」（`read_all_partial` 返回半截字节那一半）用 Mock 造不出来：要本机 server 发一半再挂住才行，`src/error_test.mbt` 的三条超时用例就是这么做的。

`MockTransport` 是公开 API（不只是测试内部工具），使用方可以用它给自己的代码写不联网的测试。
