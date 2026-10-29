// ============================================================================
// SseStream —— 按事件读的 SSE 响应。
//
// 与 `StreamResponse`（原始字节流）分开、且同样落在 `client` 包的理由：
// 它的 `next_event` 也抛 `HttpError`（读取失败的统一出口），
// 而 SSE 是另一种协议——两个类型分开，「按块读」与「按事件读」
// 各自只有一个入口，调错是编译错误。
// ============================================================================

///|
/// SSE 事件流：按事件读响应体，与 `StreamResponse`（原始字节流）分开。
///
/// **为什么不给 `StreamResponse` 加一个 `next_event`**：那个类型也是下载用的
/// 原始流，而二进制数据里 CR / LF 字节很常见，拿它喂事件解析器只会把字节流
/// 解成一堆无意义的东西（运气不好还会撞出几个假事件）。两个协议拆成两个类型，
/// 「按块读」与「按事件读」各自只有一个入口，调错是编译错误。
///
/// 拿到流时状态行与响应头就已经可用（SSE 靠这个先看状态码与 `Content-Type`）。
/// 连接生命周期与 `StreamResponse` 一致：读到 EOF 自动关闭，
/// 中途停止必须显式 `close()`。
///
/// **自动重连**由 `Config::with_sse_reconnect(...)` 开启，默认关闭。开启后
/// `next_event` 会在 EOF / 可重试错误上重订阅，`status` / `status_text` /
/// `headers` / `config` 仍然是**第一次建流**时的响应；重连失败的最新响应挂在
/// 抛出的 `HttpError::response()` 上。
pub(all) struct SseStream {
  /// HTTP 状态码
  status : Int32
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**）
  config : Config
  /// 响应体流。字段私有：`next_event` 是唯一的读取入口，
  /// 这样错误才能统一映射成 `HttpError`，也不会有人绕过解析器去读字节。
  /// 自动重连成功后会换成新连接的 body，所以需要 `mut`。
  priv mut body : @transport.ResponseBody
  /// 事件解析器的状态
  priv parser : @sse.SseParser
  /// 调用方是否已经 `close()`。
  ///
  /// 单靠关掉 `body` 不够：一次读取可能已经把好几个事件解析进了解析器的队列，
  /// 关掉连接之后它们照样取得出来。`close` 的语义是「到此为止」，
  /// 与 `StreamResponse::close()` 之后 `read_some` 只返回 `None` 保持一致。
  priv mut closed : Bool
  /// 自动重连的运行时状态；`None` 表示没有开启（保持旧的 EOF → `None` 语义）。
  priv reconnect : SseReconnectState?
} derive(Debug)

///|
pub extend SseStream with @debug.Debug::{to_repr}

///|
/// 状态码是否落在 2xx。
///
/// 与 `Response::is_success` 同义，是给自定义了 `validate_status`
/// （放行了 3xx / 4xx）的场景用的：默认配置下能拿到流就说明已经通过了校验。
pub fn SseStream::is_success(self : SseStream) -> Bool {
  self.status >= 200 && self.status < 300
}

///|
/// 读失败时的统一出口：与 `StreamResponse::read_error` 同理，把已经收到的响应
/// （状态行 + 响应头）挂到错误上——长连断掉时，`status` 与响应头是唯一能说明
/// 「对面是谁、连接建到了哪一步」的信息。
///
/// 这里没有字节可挂：读进来的字节属于解析器，要么已经变成事件，要么还在它的
/// 缓冲里，都不该在错误里重复一遍。
fn SseStream::read_error(
  self : SseStream,
  error : @transport.TransportError,
) -> HttpError {
  transport_error(
    error,
    self.config,
    Some(
      build_response(
        self.status,
        self.status_text,
        self.headers,
        b"",
        self.config,
      ),
    ),
  )
}

///|
/// 读下一个事件；没有更多事件时返回 `None`。
///
/// 事件边界、字段语义（`event:` / `data:` / `id:` / `retry:`）、注释行、
/// 多行 `data:` 合并、三种行尾都由 `@sse.SseParser` 按 WHATWG 规范处理，
/// 调用方拿到的已经是解析好的事件。
///
/// 几条与规范一致的边界：
/// - 只发了 `id:` / `retry:` 或只有心跳注释的块**不产生事件**，会继续往下读；
/// - 流结束时没等到空行的事件**丢弃**，不会补发半个事件；
/// - `close()` 之后一律返回 `None`；
/// - `SseEvent` 上的 `id` / `retry` 是解析器的持久状态快照。
///
/// **自动重连默认关闭**。开启后（`Config::with_sse_reconnect`）：
/// - 读到 EOF、读体报 `Network` / `Timeout`、或重连请求收到 5xx 时，
///   按流里最近一次 `retry:`（没有则用策略的 `default_delay`）重新订阅；
/// - 重连请求自动带 `Last-Event-ID`，值来自解析器的持久状态（只发 `id:` 的块
///   也算数）；
/// - 取消、`close()`、4xx、非 `text/event-stream` 响应、响应体解压损坏等
///   不可重试情况立即结束；
/// - 干净 EOF 且重连次数用尽时返回 `None`；最后一次失败是错误时抛该
///   `HttpError`。
///
/// 读取失败（超时、断连）时抛 `HttpError`：错误码是传输层的分类，
/// 状态码与响应头挂在 `HttpError::response()` 上。自动重连期间
/// `status` / `status_text` / `headers` / `config` 仍是第一次建流时的响应，
/// 最新一次失败的响应在抛出的错误里。
pub async fn SseStream::next_event(
  self : SseStream,
) -> @sse.SseEvent? raise HttpError {
  // 重连状态是引用语义：循环里对 attempts 的修改落在同一份状态上。
  // 策略在建流时就定了，不会在读取过程中换掉，所以这里取一次即可。
  let reconnect = self.reconnect
  while true {
    // 已经关掉的流不再吐事件：解析器的队列里可能还存着已经解出来的事件，
    // 但 `close` 就是「到此为止」。
    if self.closed {
      return None
    }
    // 先取已解析好的（一次读进来的字节可能带来多个事件），没有再读一块喂进去。
    match self.parser.next() {
      Some(event) => {
        // 交付了事件说明这条流是活的，连续失败计数从头开始。
        match reconnect {
          Some(state) => state.attempts = 0
          None => ()
        }
        return Some(event)
      }
      None => ()
    }
    let chunk = self.body.read_some() catch {
      error => {
        let failure = self.read_error(error)
        match reconnect {
          // 没开启自动重连：与旧行为一致，读失败直接抛。
          None => raise failure
          Some(state) => {
            if !retryable_error(failure) {
              raise failure
            }
            // 只有确定要重连时才丢弃上一连接未完成的事件；不可重试的错误
            // 原样抛出，调用方还能从错误里看到已经收到的响应。
            self.parser.finish()
            if !self.reconnect_loop(state, Some(failure)) {
              return None
            }
            continue
          }
        }
      }
    }
    match chunk {
      Some(bytes) => {
        self.parser.push(bytes)
        continue
      }
      None => {
        // EOF：让解析器处理末尾那个卡住的 CR，之后丢弃未完成的事件。
        self.parser.finish()
        match self.parser.next() {
          Some(event) => {
            match reconnect {
              Some(state) => state.attempts = 0
              None => ()
            }
            return Some(event)
          }
          None => ()
        }
        match reconnect {
          None => return None
          Some(state) => if !self.reconnect_loop(state, None) { return None }
        }
        continue
      }
    }
  } nobreak {
    None
  }
  // `while true` 的兜底值；正常路径都走 return / raise，不会到这里。
}

///|
/// 关闭响应体流并释放连接。幂等。
///
/// 读了几个事件就不想读了（例如任务结束）时必须显式调用，否则连接会一直挂着。
/// 关闭之后 `next_event` 一律返回 `None`——包括那一次读取里已经解析好、
/// 还排在解析器队列里的事件。与 `StreamResponse::close()` 的语义一致：
/// `close` 就是「到此为止」，不是「释放连接但还能接着读」。
pub fn SseStream::close(self : SseStream) -> Unit {
  self.closed = true
  self.body.close()
}
