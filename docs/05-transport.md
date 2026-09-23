# 05 传输层契约

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/transport/transport.mbt` | `Transport` trait、`PreparedRequest`、`RawResponse`、`TransportError` |
| `src/transport/stream.mbt` | `ResponseBody`：响应体流（真实连接 / 内存体两种来源） |
| `src/transport/async_http.mbt` | 真实实现（唯一对接 `moonbitlang/async` 的文件） |
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

`RawResponse` 是**纯传输结果**，刻意不叫 `Response`（上层的 `Response` 还要承担响应体解码与状态码校验）：

| 字段 | 含义 |
|---|---|
| `status` | HTTP 状态码 |
| `status_text` | 原因短语 |
| `headers` | 响应头（本项目自己的 `Headers`，大小写不敏感） |
| `body` | **响应体流**（`ResponseBody`），不是字节 |

`TransportError` 只有三类：`Timeout` / `Network(String)` / `Unsupported(String)`。分类的用途见 `04-errors.md`。

### 为什么 `body` 是流

`send` 返回时只保证「状态行 + 响应头已经到手」，响应体按需读。底层原语只保留最弱的能力，一次性读全是**上层**的组合结果（`Client::request` 就是 `read_all()` 之后按 `response_encoding` 解码）。这样 chunked / SSE 这类「边到边读」的协议才有落点——SSE 的全部要求就是「先看状态码与 `Content-Type`，再一段段取数据」。

### `ResponseBody` 契约

```moonbit
pub fn ResponseBody::from_bytes(Bytes) -> ResponseBody   // 内存体：Mock 与自定义实现用
pub async fn ResponseBody::read_some(Self, max_len? : Int) -> Bytes? raise TransportError
pub async fn ResponseBody::read_until(Self, sep : String) -> String? raise TransportError
pub async fn ResponseBody::read_all(Self) -> Bytes raise TransportError
pub async fn ResponseBody::read_all_partial(Self) -> (Bytes, TransportError?) noraise
pub fn ResponseBody::close(Self) -> Unit
```

两种来源（真实连接、内存字节）的语义**完全一致**，对齐 `@io.Reader`，Mock 才能真实代表网络侧：

- `read_some` 到 EOF 返回 `None`；返回的块大小不保证（取决于对端一次发了多少）；
- `read_until` 消费掉分隔符且不返回它；EOF 时把剩余内容当作最后一段返回，再读一次才是 `None`；
- `read_all` 读完剩余内容，空体返回空字节串；
- **`read_all_partial` 与 `read_all` 读到的字节相同，区别只在失败时**：失败不当异常抛出，而是返回 `(已读到的部分, Some(错误))`——网络在读到一半断掉时，已经到手的字节往往正是现场（错误响应的正文、下载进度），上层要把它们挂到错误上（见 `04-errors.md`）。`read_all` 就是它的「失败即抛」包装；
- **读到 EOF 会自动关闭底层连接**——本项目不复用连接，早关没有代价；`read_all_partial` 在失败时同样关闭（两种结局都关）；
- `close()` 幂等。没有析构器，**拿到流后不读完也不 `close()` 会漏一条连接**；
- 任何读取失败都会先关闭流再抛 `TransportError`：失败之后连接状态已不可信，调用方不该继续读。

`read_all_partial` 的声明带 `noraise`：MoonBit 里 async 函数省略错误类型**不等于**不抛错（省略等于开放错误类型），要表达「不抛」必须显式写 `noraise`。

**不要用 `read_until("\n\n")` 切 SSE 事件。** CRLF 流上事件边界的字节是 `0D 0A 0D 0A`，里面没有连续两个 `0A`，这个分隔符永远匹配不到：内存体上表现为「整段原样返回」，真实连接上更糟——EOF 不会来，于是会一直等到连接关闭（不限时的 SSE 配置下就是永远等下去）。事件切分要按规范认 CRLF / LF / CR 三种行尾，落在**根包**的 `SseParser` 里，不在传输层，见 `06-sse.md`；`src/transport/stream_test.mbt` 有一条用例专门钉住这个坑。

`ResponseBody` 刻意**不**实现 `@io.Reader`：那要实现 `_get_internal_buffer` / `_direct_read` 这两个标注「仅内部实现」的方法。只暴露上面四个方法，底层库换 Reader 实现也不会波及本模块。

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

配套的四处适配：

1. **地址切分**（`split_url`）：底层 `Client::Client(uri)` 要求 uri 的 path 恰好是 `/`（否则抛 `InvalidFormat`），路径必须留给 `Client::request(meth, path)`。切法镜像底层私有的 `resolve_url`：按 `://` 分出协议，取之后第一个 `/` 之前的部分作为 host、其余作为 path+query。相对地址与非 http/https 协议抛 `TransportError::Unsupported`——同一类输入以前走 `@http.request` 时会被归到 `Network`，现在分类更准（`Unsupported` 的定义就是「请求还没发出去就失败了」）。
2. **枚举映射**：本项目的 `Method` 与底层的 `RequestMethod` 一一对应（`to_request_method`）。上层不认识底层类型，所以映射写在这里。
3. **头的容器转换**：底层要求 `Map[CaseInsensitiveString, String]`（`to_http_headers` / `from_http_headers`）。两边都是大小写不敏感的容器，转换只搬类型不改语义。头与便捷函数一样在 `Client::Client` 建连时一次性交出，body 单独 `write`，语义与改造前一致。
4. **超时与错误收敛**：见上文「超时语义」；底层 `TimeoutError` → `TransportError::Timeout`，其余错误统一归 `Network` 并保留原始错误文本。建连之后任何失败都靠 `errdefer client.close()` 关连接，不留半开连接。

### 尚未处理的能力（改动时的落点）

| 能力 | 现状 | 可能的实现方式 |
|---|---|---|
| 连接复用 | 每次请求新建连接 | 按 host 缓存 `@http.Client`；注意本项目不回传连接池状态给上层，缓存要自己做失效处理 |
| 请求体流式上传 | 不支持（`PreparedRequest::body` 是完整字节） | 需要 `ResponseBody` 的对偶：一个挂在 `@http.Client` 上的可写流，`write` 完再 `end_request()` |
| 上传进度 | 不支持 | 与上一条一起做；下载进度不需要新 API——调用方按 `read_some` 的每块大小累加即可 |
| 代理 | 不支持 | `Client::Client(uri, proxy~)` 与 `@http.request(proxy~)` 都有这个参数，需要在 `Config` 里加 `proxy` 字段并传进来 |
| TLS 校验开关 | 固定为默认（校验） | `Client::Client(trust~ / verify~)` |
| 响应 cookie | 读不到 `Set-Cookie` | 底层把响应 cookie 单独放在 `Response::cookies` 里，没有并进 headers。要暴露需要先决定多值头的表示（本项目的 `Headers` 一个名字只能有一个值） |
| SSE 事件解析 | 已实现，但**不在本模块** | 传输层只交出字节流；事件边界与 `event:` / `data:` 字段语义在 `sse` 包（`SseParser`），接到 HTTP 上的入口是根包的 `Client::sse` / `SseStream`，见 `06-sse.md`。分层的意义是「字节怎么来」与「字节怎么解」各自独立演进：换成别的字节来源（WebSocket、文件）也能复用同一个解析器 |

改动这些能力时请只动 `src/transport/`——它是本模块唯一对接 `moonbitlang/async` 的包（`src/transport/*.mbt` 都可以改，不限于 `async_http.mbt`）。`PreparedRequest` 的字段语义不要动；`RawResponse` 的结构变化（例如本次 `body` 由字节改成流）必须同步本节与 `03-request-pipeline.md`，因为它出现在公开签名里。

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
