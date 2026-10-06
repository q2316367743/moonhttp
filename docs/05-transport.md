# 05 传输层契约

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/transport/transport.mbt` | `Transport` trait、`PreparedRequest`、`RawResponse`、`TransportError` |
| `src/transport/stream.mbt` | `ResponseBody`：响应体流（自研栈连接流 / 内存体两种来源），按块读的部分 |
| `src/transport/stream_lifecycle.mbt` | `ResponseBody` 的构造与释放（`from_bytes` / `open_wire` / `rewind` / `close`），含取消登记 |
| `src/transport/stream_all.mbt` | `ResponseBody` 的「读全量」三件套（`drain_into` / `read_all_partial` / `read_all`）与下载进度的逐块报告 |
| `src/transport/decode.mbt` | `Content-Encoding` 的解码工具：`decode_gzip`（整份字节的内存解压，缓冲路径用）与 `declares_gzip`（认定 gzip 的唯一判据），见 `15-response-compression.md` |
| `src/transport/mock.mbt` | 测试用实现：记录请求、按队列返回响应、可注入失败 |
| `src/httpconn/` | 真实实现（自研 HTTP/1.1 栈，2026-09-30 起为缺省传输；旧的 `AsyncHttpTransport` 已删除），见 `18-httpconn-transport.md` |
| `src/transport/transport_test.mbt` | 传输层自身的用例 |
| `src/transport/stream_test.mbt` | 响应体流的读语义（内存体） |

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

两种来源（自研栈连接流、内存字节）的语义**完全一致**，对齐 `@io.Reader`，Mock 才能真实代表网络侧：

- `read_some` 到 EOF 返回 `None`；返回的块大小不保证（取决于对端一次发了多少）；
- `read_until` 消费掉分隔符且不返回它；EOF 时把剩余内容当作最后一段返回，再读一次才是 `None`；
- `read_all` 读完剩余内容，空体返回空字节串；
- **`read_all_partial` 与 `read_all` 读到的字节相同，区别只在失败时**：失败不当异常抛出，而是返回 `(已读到的部分, Some(错误))`——网络在读到一半断掉时，已经到手的字节往往正是现场（错误响应的正文、下载进度），上层要把它们挂到错误上（见 `04-errors.md`）。`read_all` 就是它的「失败即抛」包装；
- **读到 EOF 会自动关闭底层连接**——本项目不复用连接，早关没有代价；`read_all_partial` 在失败时同样关闭（两种结局都关）；
- `close()` 幂等。没有析构器，**拿到流后不读完也不 `close()` 会漏一条连接**；
- 任何读取失败都会先关闭流再抛 `TransportError`：失败之后连接状态已不可信，调用方不该继续读。

**流的字节里没有「内容编码」这一层**：`ResponseBody` 交出去的永远是实体字节（`Content-Encoding` 已经被负责解码的一方消掉）。
缓冲路径是上层读完自己解；流式路径在 httpconn 里由本库声明并解压（谁解压谁声明）——
口径、谁声明压缩、响应头怎么跟着变，见 `15-response-compression.md` 与 `18-httpconn-transport.md`。自定义传输实现若要交出 gzip 字节，就必须把 `Content-Encoding` 一起交出去（让头与体说同一件事）。

`read_all_partial` 的声明带 `noraise`：MoonBit 里 async 函数省略错误类型**不等于**不抛错（省略等于开放错误类型），要表达「不抛」必须显式写 `noraise`。

**不要用 `read_until("\n\n")` 切 SSE 事件。** CRLF 流上事件边界的字节是 `0D 0A 0D 0A`，里面没有连续两个 `0A`，这个分隔符永远匹配不到：内存体上表现为「整段原样返回」，真实连接上更糟——EOF 不会来，于是会一直等到连接关闭（不限时的 SSE 配置下就是永远等下去）。事件切分要按规范认 CRLF / LF / CR 三种行尾，落在**根包**的 `SseParser` 里，不在传输层，见 `06-sse.md`；`src/transport/stream_test.mbt` 有一条用例专门钉住这个坑。

`ResponseBody` 刻意**不**实现 `@io.Reader`：那要实现 `_get_internal_buffer` / `_direct_read` 这两个标注「仅内部实现」的方法（它们要命名 async 包内部的 `ReaderBuffer`，跨模块做不到），也会把「底层换 Reader 实现」这件事漏进本模块。只暴露上面五个方法。
gzip 解压因此也不在流上做：缓冲路径读完再解（`decode_gzip` 借一个内存管道把字节喂给 `@gzip.Decoder`），流式路径在 httpconn 内用同一个解码器包住分帧 reader，见 `15-response-compression.md`。

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
| 取消已经发生之后 | `ResponseBody` 挂在信号上的那条登记会 `close()` 连接——调用方取消之后不再读也不会漏连接（`close` 幂等，注销发生在 `close()` 里）；`ResponseBody::open_wire` 进来时信号已取消则当场关闭这条连接 |

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

## 真实实现的落点

真实实现是自研 HTTP/1.1 栈 `HttpConnTransport`（2026-09-30 起为 `Client::new` 的缺省
transport；旧的 `AsyncHttpTransport`——基于 `moonbitlang/async/http` 的四步式——已整体
删除）。请求行/头块渲染、分帧判定、chunked 解码都在协议层 `httpproto`（纯逻辑、同步
可测），拨号 / 写入 / 读取在实现层 `httpconn`；设计口径、分帧判定四规则、gzip 的
「谁解压谁声明」、新旧栈行为对照（历史）见 `18-httpconn-transport.md`。

### 尚未处理的能力（改动时的落点）

| 能力 | 现状 | 可能的实现方式 |
|---|---|---|
| 连接复用 | 每次请求新建连接（发 `Connection: close`） | 连接池是 httpconn 第 2 期（2026-10），契约已定：体未消费完不回池、取消=毒化，见 `docs/17` 分期表 |
| 请求体流式上传 | **已支持**（`PreparedRequest.body : RequestBody?` 的 `Stream` 形态，`with_data_from_stream`） | 泵循环 + 定长 / chunked 双模式分帧；契约见 `20-streaming-upload.md` |
| 上传进度 | **已支持**（`PreparedRequest::on_upload_progress`）：按 64 KiB 分块写 + 每块写完回调 | 粒度见 `httpconn/request_write.mbt` 的 `UPLOAD_CHUNK_SIZE`；契约见 `10-progress.md` |
| 下载进度 | **已支持**（`ResponseBody` 的 `read_all*` 带 `on_progress`），只由「库读全量」触发 | 见 `10-progress.md` |
| 代理 | 已支持（`PreparedRequest::proxy`） | httpconn 自己实现的 CONNECT 隧道（凭据只落隧道请求）；SOCKS5 见 `18-httpconn-transport.md` 的留位。契约见 `09-proxy.md` |
| TLS 校验开关 | 固定为默认（校验，SNI=目标 host） | `Tls::client(trust~ / verify?)` 透传 |
| 自定义请求方法 | **已支持**（`Method::Other(String)`，httpconn 原样发送，token 校验在建连前） | 见 `18-httpconn-transport.md`；旧栈受底层封闭枚举所限（历史证据见 `16-custom-http-methods.md`） |
| 响应 cookie | **已支持**（`RawResponse.set_cookies` 多值出口 + `Client::new(cookie_jar~)` 的自动维护）：httpconn 从响应头原文收集 | 契约与实现见 `19-cookies.md` |
| SSE 事件解析 | 已实现，但**不在本模块** | 传输层只交出字节流；事件边界与 `event:` / `data:` 字段语义在 `sse` 包（`SseParser`），接到 HTTP 上的入口是根包的 `Client::sse` / `SseStream`，见 `06-sse.md`。分层的意义是「字节怎么来」与「字节怎么解」各自独立演进：换成别的字节来源（WebSocket、文件）也能复用同一个解析器 |

改动这些能力时请只动 `src/transport/`（trait 与响应体流）与 `src/httpconn/`（真实网络实现，唯一碰网络与 async HTTP 设施的包）。`PreparedRequest` 的字段语义不要动（加字段是加能力，比如 `proxy`；改已有字段的含义不是）；`PreparedRequest` / `RawResponse` 的结构变化（例如本次 `body` 由字节改成流、`proxy` 字段的加入）必须同步本节与 `03-request-pipeline.md`，因为它们出现在公开签名里。

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
