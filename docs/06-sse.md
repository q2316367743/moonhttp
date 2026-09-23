# 06 SSE 事件解析

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/sse/sse.mbt` | `SseEvent`、`SseParser` 的状态与公开入口（`new` / `push` / `next` / `finish`）、事件分发规则 |
| `src/sse/sse_parse.mbt` | 字节级细节：找行尾、切字段、解析 `id` / `retry` 的值 |
| `src/facade.mbt` | `SseStream` 类型与 `next_event`：把解析器接到 HTTP 响应体上（根包门面层） |
| `src/client.mbt` | `Client::sse`：入口，含 `text/event-stream` 准入检查 |
| `src/sse/sse_test.mbt` | 规范逐条用例（纯逻辑，同步测试） |
| `src/sse_stream_test.mbt` | 接到 HTTP 之后的用例，含本机 server 的真实 CRLF 长连验收用例 |

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
// 解析器（包 q2316368843/moonhttp/sse，根包用 pub using 再导出）
pub(all) struct SseEvent {
  event : String   // 事件类型，缺省 "message"
  data : String    // 多条 data: 行用 "\n" 连接
  id : String?     // 见「持久状态」
  retry : Int?     // 见「持久状态」
}
pub fn SseParser::new() -> SseParser
pub fn SseParser::push(Self, Bytes) -> Unit   // 喂字节
pub fn SseParser::next(Self) -> SseEvent?     // 取一个已完成的事件
pub fn SseParser::finish(Self) -> Unit        // 读到 EOF 时调用一次

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

**本项目不自动重连**（不做 `retry` 退避、不重订阅），但把这两个值交给调用方，重连逻辑写在上层。这样库不用替调用方决定「重试几次算够」「要不要换地址」。

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

`Client::sse` 拿到响应头后立刻检查 `Content-Type` 是否声明了 `text/event-stream`（判定与 `StreamResponse::is_event_stream` 共用 `declares_event_stream`）。不是就关掉连接并抛 `ErrorCode::NotSupported`。

错误里挂着**已经收到的响应**（状态行与响应头），所以调用方看得见「回来的到底是什么」；**body 不读**——声明了别的类型就可能是任意大小的二进制，要看原文得改用 `Client::stream`。这条与其它路径「失败也带响应」的规则一致，见 `04-errors.md`。

这与 `Client::sse` 之外那些「按声明决定怎么处理」的规则同源：**该不该用这种读法，由声明的类型决定**。把 JSON 或二进制按事件读只会得到一堆莫名其妙的东西，宁可响亮失败。

确实要接一个不声明类型的服务端时，逃生口是公开的：用 `Client::stream` 拿原始字节流，再把 `read_some` 的字节喂给 `SseParser`。这种情况下由调用方自己的决定负责，库不猜。

## 前提：超时不限

SSE 的长连要求 `timeout` 不限时。内置默认值就是不限时（`defaults()` 给的是 `Some(0)`，`<= 0` 一律视为不限时），所以在默认实例上直接 `sse` 就能长连；显式设过 `timeout` 的实例要用 `with_timeout(0)` 关掉。读取阶段的超时是**单次读取**的等待上限，见 `05-transport.md` 的「超时语义」——事件之间长时间没有数据是正常的，不能被当成超时（`sse_stream_test.mbt` 有一条用例专门钉这个语义）。

## 改动时的同步清单

1. **改解析规则**：先想清楚是哪一条规范，在 `src/sse/sse_test.mbt` 加一条用例再改代码；CRLF 家族（裸 CR 收尾、CR 跨块）最容易改坏。
2. **改 `SseEvent` 的字段**：它出现在公开签名里，要同步本节与 `README.mbt.md`。
3. **改 `ResponseBody::read_until` 的语义**：`docs/05-transport.md` 与本节的「为什么不能用」都要复查。
4. **加自动重连**：那是一个新能力，不是解析规则的一部分；它需要决定「何时放弃重试」「如何取消」，应当先补一节设计再动手。
5. **把 SSE 读法加回 `StreamResponse`**：不要这样做，理由见开头第 2 条。
