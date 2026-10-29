# 06 SSE 事件解析

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/sse/sse.mbt` | `SseEvent`、`SseParser` 的状态与公开入口（`new` / `push` / `next` / `finish` / `begin_stream`）、持久状态读取、事件分发规则 |
| `src/sse/sse_parse.mbt` | 字节级细节：找行尾、切字段、解析 `id` / `retry` 的值 |
| `src/client/sse_stream.mbt` | `SseStream` 类型与 `next_event`：把解析器接到 HTTP 响应体上（编排层） |
| `src/client/sse_reconnect.mbt` | 自动重连：运行时状态、错误分类、等待与重订阅循环 |
| `src/client/stream_entry.mbt` | `Client::sse`：入口，含 `text/event-stream` 准入检查 |
| `src/config/sse.mbt` | `SseReconnect` 策略与 `Config::with_sse_reconnect` |
| `src/sse/sse_test.mbt` | 规范逐条用例（纯逻辑，同步测试） |
| `src/sse/reconnect_test.mbt` | 重连相关的解析器状态：`last_event_id` / `retry_interval` / `begin_stream` |
| `src/sse_stream_test.mbt` | 接到 HTTP 之后的用例，含本机 server 的真实 CRLF 长连验收用例 |
| `src/sse_reconnect_test.mbt` | 自动重连的端到端用例（Mock / 脚本化传输层） |

## 三件分层上的事（先说清，免得改的时候踩回去）

**1. 解析器是独立包 `sse`，不是根包的文件。** 理由与 `config` / `headers` / `merge` / `url` 完全相同：它只吃字节、不碰网络与 async，独立成包后能用同步测试覆盖规范逐条，也能被任何字节来源复用（文件、WebSocket）。依赖方向 `sse → core`。

**2. 按事件读是独立的类型 `SseStream`，不是 `StreamResponse` 上的方法。** `StreamResponse` 是**下载**用的原始字节流，而二进制数据里 CR / LF 字节很常见——在它上面喂事件解析器，只会把字节流解成一堆无意义的东西（运气不好还会撞出几个假事件）。两个协议拆成两个类型之后，「按块读」与「按事件读」各自只有一个入口，调错是编译错误。

**3. `Client::sse` 在入口处检查 `Content-Type`。** 见文末「准入检查」。

## 先讲为什么：`read_until("\n\n")` 不行

SSE 规范允许行尾是 **CRLF / LF / CR** 三种。CRLF 流上事件边界（空行）的字节是 `0D 0A 0D 0A`，里面**没有**连续两个 `0A`，所以拿 `"\n\n"` 当分隔符永远匹配不到：

- 内存体上表现为「一个分隔符都没找到 → 整段原样返回」，拿到的东西连边界都没切掉；
- 真实连接上更糟——EOF 不会来，于是会一直等到连接关闭；不限时的 SSE 配置下就是**永远等下去**。

`src/transport/stream_test.mbt` 有一条用例专门钉住这个坑，`ResponseBody::read_until` 的文档也写了「不要用它切 SSE 事件」。事件切分因此按字节扫，自己识别三种行尾。

另一个理由是字段：SSE 的全部内容不只是「切出片段」，还包括 `event:` / `data:` / `id:` / `retry:` 的语义。只给片段等于把 EventSource 规范推给调用方重写一遍。

## 公开 API

```moonbit
// 解析器（包 q2316367743/moonhttp/sse，根包用 pub using 再导出）
pub(all) struct SseEvent {
  event : String   // 事件类型，缺省 "message"
  data : String    // 多条 data: 行用 "\n" 连接
  id : String?     // 见「持久状态」
  retry : Int32?   // 见「持久状态」
}
pub fn SseParser::new() -> SseParser
pub fn SseParser::push(Self, Bytes) -> Unit       // 喂字节
pub fn SseParser::next(Self) -> SseEvent?         // 取一个已完成的事件
pub fn SseParser::finish(Self) -> Unit            // 读到 EOF 时调用一次
pub fn SseParser::last_event_id(Self) -> String?  // 持久状态：最近一次 id:
pub fn SseParser::retry_interval(Self) -> Int32?  // 持久状态：最近一次 retry:
pub fn SseParser::begin_stream(Self) -> Unit      // 同一个解析器接新连接（重连）

// 自动重连策略（config 包，根包再导出）
pub(all) struct SseReconnect {
  max_retries : Int32?   // None = 不限次数
  default_delay : Int32  // 流里没有 retry: 时的间隔（毫秒）
}
pub fn Config::with_sse_reconnect(Self, SseReconnect) -> Config

// 入口与事件流（根包）
pub async fn Client::sse(Self, Config) -> SseStream raise HttpError
pub async fn SseStream::next_event(Self) -> SseEvent? raise HttpError
pub fn SseStream::close(Self) -> Unit
```

典型用法（`next_event` 会自己调用 `push` / `finish`，不需要手动管）：

```moonbit
let events = api.sse(Config::new(url))
while events.next_event() is Some(event) {
  println(event.event + ": " + event.data)
}
```

`SseParser` 是独立的公开类型，不只是内部实现：它既能被 `SseStream` 驱动，也能用在别的字节来源上，还是「服务端不声明 `text/event-stream`」时的逃生口（见文末）。

## 解析规则（对齐 WHATWG EventSource）

| 规则 | 实现落点 |
|---|---|
| 行尾认 CRLF / LF / CR 三种 | `find_line_end` |
| BOM 只忽略流开头的那个，且要等够三个字节才判定 | `skip_bom` |
| 空行分发事件 | `handle_line` → `dispatch` |
| `:` 开头的整行是注释（`: ping` 心跳），忽略 | `handle_line` |
| 第一个 `:` 前是字段名、后是值；值只去掉**一个**前导空格 | `split_field` |
| 行内没有 `:` 时字段名是整行、值为空串 | `split_field` |
| `data`：值追加进缓冲 | `handle_line` |
| `event`：设置事件类型缓冲（只对当前块有效，分发后清空） | `handle_line` / `dispatch` |
| `id`：值不含 U+0000 才生效（含 NUL 会导致重连时塞出非法请求头） | `has_nul` |
| `retry`：值必须全为 ASCII 数字，否则整体忽略；超范围忽略 | `parse_retry` |
| 其它字段一律忽略 | `handle_line` 的 `_` 分支 |
| 分发时 data 缓冲为空则**不发事件** | `dispatch` |
| 未以换行收尾的半行在 EOF 丢弃，不补发 | `finish` |

两条容易踩的细节：

- **`data:` 写空值不算「空」**：`data:\n\n` 会产生一个 data 为空串的事件，而「一个块里没有出现过 `data:`」才是不发事件。
- **多条 `data:` 行的连接方式**：规范的说法是「逐行追加值再补一个 `\n`，分发前去掉最后一个 `\n`」。实现直接把这几个值用 `\n` 连起来（`join_lines`），等价且不必回头删字符。

## 持久状态：`id` 与 `retry`

`SseEvent` 上的 `id` / `retry` 是**解析器当前状态的快照，跨事件持久**——对齐规范里 EventSource 的内部状态。一旦流里出现过 `id: 42`，后面每个事件都会带着 `Some("42")`，而不是只有设置它的那一个事件有。

这么设计是因为断线重连需要它们：重连时要带 `Last-Event-ID: 42` 请求头、并按 `retry` 的间隔重试。

解析器只负责维护状态，不决定何时重连：

- `SseParser::last_event_id()` / `retry_interval()` 直接读当前值；只发了 `id:` / `retry:` 的块也算（哪怕没有事件分发）；
- 开启自动重连时，`SseStream` 用这两个值重订阅；
- 没开启时，它们照常出现在每个 `SseEvent` 上，调用方可以按同样的信息自己写重连逻辑。

## 自动重连

**默认关闭**。不设置 `Config::sse_reconnect` 时行为与从前完全一致：读到 EOF 返回 `None`，不重订阅。

开启方式：

```moonbit nocheck
let events = api.sse(
  Config::new("/events").with_sse_reconnect(
    SseReconnect::new()          // 不限次数、默认间隔 3000ms
      .with_max_retries(5)       // 连续 5 次没有交付事件后放弃
      .with_default_delay(1000), // 流里没有 retry: 时用 1s
  ),
)
while events.next_event() is Some(event) {
  println(event.event + ": " + event.data)
}
```

策略字段：

| 字段 | 默认 | 含义 |
|---|---|---|
| `max_retries` | `None` | `None` = 不限次数；`Some(n)` = 连续 n 次重连都没有交付事件后放弃；`0` = 不重连 |
| `default_delay` | `3000` | 流里没有 `retry:` 时使用的间隔（毫秒） |

间隔优先取流里最近一次生效的 `retry:`（只发 `retry:` 的块也算），没有才用 `default_delay`；不做指数退避。`retry: 0` 会立即重连——服务端连续关闭时会形成忙循环，使用方自己保证流里有合理的 `retry:`。

### 什么时候重连

| 场景 | 行为 |
|---|---|
| 读到干净 EOF | 按策略重连 |
| 读体报 `Network` / `Timeout` | 按策略重连 |
| 读体报 `Cancelled` | 立即抛 `ERR_CANCELED`，不重连 |
| 读体报 `BadResponse`（例如 gzip 损坏） | 抛错，不重连 |
| 重连请求 5xx | 按策略重试 |
| 重连请求 4xx / 3xx / `NotSupported` / `InvalidUrl` / `TooManyRedirects` | 立即抛错，不重试 |
| 重连响应没有声明 `text/event-stream` | 关掉新连接后抛 `NotSupported`，不重试 |
| 干净 EOF 且次数用尽 | `next_event()` 返回 `None` |
| 最后一次失败是错误且次数用尽 | 抛最后一个 `HttpError` |

分类时先看 `HttpError::response()` 的状态码：5xx 重试，其它非 2xx（4xx / 3xx / …）直接不重试；没有响应或 2xx 时才看错误码（`Network` / `Timeout` 重试，其余不重试）。取消永远不重试。

### `Last-Event-ID` 与重发的请求

- 重连请求自动带 `Last-Event-ID: <解析器的 last_event_id>`；空字符串 id 不写头，解析器还没有 id 时保留调用方自己设置的头。
- 重连从**原始 `Config`** 出发重新走完整管线：合并实例默认值、请求拦截器、重定向、cookie、状态码校验都会再跑一遍。策略在第一次建流时确定，不会在重连过程中换掉。
- 重连会按原配置重发请求；带一次性流式请求体（`with_data_from_stream`）的 SSE 请求无法重放，不要开启自动重连（与重定向的流式体约束同源，见 `20-streaming-upload.md`）。
- 同一个 `SseParser` 跨连接复用：`id` / `retry` 保留；新连接开始前调用 `begin_stream()`，只重置 BOM 判定与上一连接残留的半行，不清持久状态。

### 怎么停

- `SseStream::close()`：后续 `next_event()` 返回 `None`。它**不会打断正在进行的重连等待**（等待最长是当前的 `retry` 间隔）；要立刻停请用取消。
- `AbortController::abort(...)`：立刻打断读取或重连等待，`next_event()` 抛 `ERR_CANCELED`，不会退化成 `None`——结束一条流的两条路与从前一致（见 `12-cancellation.md`）。
- 首次 `Client::sse` 建连失败**不会**自动重试（那时还没有 `SseStream` 承载重连状态），仍然直接抛错。

`SseStream.status` / `status_text` / `headers` / `config` 保持**第一次建流**时的响应；重连失败的最新响应挂在抛出的 `HttpError::response()` 上。

## 跨块安全与 `finish`

`push` 的输入是「对端一次送到的字节」，切分点完全不可控：可能切在行尾中间、字段中间、甚至一个 UTF-8 字符中间。两条保证：

- 解析器只在**整行**到手后才解码（`decode_lossy`），所以多字节字符被切碎也不会解出乱码；`sse_test.mbt` 有一条逐字节喂入的用例。
- CR 落在缓冲区末尾时**先不消费**：它可能是 CRLF 的前半，提前消费会把一次换行当成两次，凭空多切出一个空行（= 一个假事件）。

代价是末尾那个卡住的 CR 需要外部告知「不会再有数据了」——这就是 `finish()` 存在的唯一理由。读到 EOF 却没调用它，`data: x\r\r` 这类以裸 CR 收尾的流会少发最后一个事件。`SseStream::next_event` 在读到 EOF 时自动调用，直接用 `SseParser` 的调用方需要自己调。

`finish()` 还会丢弃未完成的事件块（规范要求），重复调用是安全的。

## `close()` 是「到此为止」，不是「只释放连接」

一次读取可能已经把好几个事件解析进了解析器的队列（对端一次发来多个事件是常态）。所以 `SseStream::close()` 除了关闭连接，还会让后续 `next_event()` 一律返回 `None`——否则会出现「我明明关了，它又吐了一个事件」这种怪事。这与 `StreamResponse::close()` 的语义一致：那边关掉之后 `read_some` 也只返回 `None`。

需要「读完已经到手的再走」就不要 `close()`，直接停止调用 `next_event()` 就行（连接会由读到 EOF 或进程结束回收；长连场景下想立刻释放就必须 `close()`）。

## 准入检查：`Content-Type` 在入口处强制

`Client::sse` 拿到响应头后立刻检查 `Content-Type` 是否声明了 `text/event-stream`（判定与 `StreamResponse::is_event_stream` 共用 `src/util/response.mbt` 的 `declares_event_stream`）。不是就关掉连接并抛 `ErrorCode::NotSupported`。

错误里挂着**已经收到的响应**（状态行与响应头），所以调用方看得见「回来的到底是什么」；**body 不读**——声明了别的类型就可能是任意大小的二进制，要看原文得改用 `Client::stream`。这条与其它路径「失败也带响应」的规则一致，见 `04-errors.md`。

这与 `Client::sse` 之外那些「按声明决定怎么处理」的规则同源：**该不该用这种读法，由声明的类型决定**。把 JSON 或二进制按事件读只会得到一堆莫名其妙的东西，宁可响亮失败。

确实要接一个不声明类型的服务端时，逃生口是公开的：用 `Client::stream` 拿原始字节流，再把 `read_some` 的字节喂给 `SseParser`。这种情况下由调用方自己的决定负责，库不猜。

## 前提：超时不限

SSE 的长连要求 `timeout` 不限时。内置默认值就是不限时（`defaults()` 给的是 `Some(0)`，`<= 0` 一律视为不限时），所以在默认实例上直接 `sse` 就能长连；显式设过 `timeout` 的实例要用 `with_timeout(0)` 关掉。读取阶段的超时是**单次读取**的等待上限，见 `05-transport.md` 的「超时语义」——事件之间长时间没有数据是正常的，不能被当成超时（`sse_stream_test.mbt` 有一条用例专门钉这个语义）。

自动重连的等待**不经过 `timeout`**：它用的是流里的 `retry:` 或策略的 `default_delay`，并且由取消信号打断（`sleep_with_abort`，见 `12-cancellation.md`）。每次重连建立的连接仍按原配置的 `timeout` 约束。

## 改动时的同步清单

1. **改解析规则**：先想清楚是哪一条规范，在 `src/sse/sse_test.mbt` 加一条用例再改代码；CRLF 家族（裸 CR 收尾、CR 跨块）最容易改坏。
2. **改 `SseEvent` 的字段**：它出现在公开签名里，要同步本节与 `README.mbt.md`。
3. **改 `ResponseBody::read_until` 的语义**：`docs/05-transport.md` 与本节的「为什么不能用」都要复查。
4. **改自动重连**：策略与构建器在 `src/config/sse.mbt`，错误分类 / 等待 / 重订阅在 `src/client/sse_reconnect.mbt`，解析器状态在 `src/sse/sse.mbt`。先改本节的契约表与 `src/sse_reconnect_test.mbt` 的用例。**结束一条已经在消费的流仍然只有两条路**：`SseStream::close()`（就到此为止），或者用 `AbortController::abort(...)` 取消（`next_event` 会抛 `ERR_CANCELED` 而不是返回 `None`，见 `12-cancellation.md`）——别把「取消」实现成返回 `None`，那会和「服务端正常结束事件流」混在一起。
5. **把 SSE 读法加回 `StreamResponse`**：不要这样做，理由见开头第 2 条。
