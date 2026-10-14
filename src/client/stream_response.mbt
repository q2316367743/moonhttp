// ============================================================================
// StreamResponse —— 原始字节流响应（下载）。
//
// 它在 `client` 包而不在 `response` 包，原因是「读取随时可能失败」：
// `read_some` / `read_until` / `read_all` 失败时抛 `HttpError`（错误里带着
// 已经收到的响应），而 `response` 包的定位是不抛 `HttpError` 的纯值——
// 会抛错的类型与会造错的抛错点（errors.mbt）待在同一个包里。
// ============================================================================

///|
/// 流式响应：状态行与响应头已经到手，响应体按需读取。
///
/// 这是**原始字节流**的入口（下载、边到边处理都走它）。按事件读 SSE
/// 是另一种协议，用 `Client::sse` 拿到的 `SseStream`——两边类型分开，
/// 「按块读」与「按事件读」各自只有一个入口，调错是编译错误而不是
/// 把二进制数据解成一堆无意义的事件。
///
/// 与 `Response` 的差别都由「响应体还没读」这一条派生出来：
/// - 没有 `text()` / `bytes()` / `json()`：字节还没读出来，读多少由调用方
///   经 `read_some` / `read_until` / `read_all` 决定（`Response` 是已经读完的那份）；
/// - 响应体可能无限长，`Response` 那条「读全量再交出去」的路在这里不成立；
/// - 读取随时可能失败：统一抛 `HttpError`，错误里带着**已经收到的响应**
///   （状态行与响应头一定在；`read_all` 读到一半失败时还有已读到的字节），
///   调用方不必认识传输层错误。
///
/// 状态码与响应头这些「不读 body 就能拿到」的信息与 `Response` 保持一致，
/// 所以拿到流之后可以先按状态码与 `Content-Type` 决定怎么读。
pub(all) struct StreamResponse {
  /// HTTP 状态码
  status : Int32
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**），与 axios 的 `response.config` 一致
  config : Config
  /// 响应体流。字段私有：读取入口都在本类型的方法上，
  /// 这样错误才能统一映射成 `HttpError` 而不是把传输层错误漏出去。
  priv body : @transport.ResponseBody
} derive(Debug)

///|
pub extend StreamResponse with @debug.Debug::{to_repr}

///|
/// 状态码是否落在 2xx。
///
/// 与 `Response::is_success` 一样，是给自定义了 `validate_status`
/// （放行了 3xx/4xx）的场景用的：默认配置下能拿到响应就说明已经通过了校验。
pub fn StreamResponse::is_success(self : StreamResponse) -> Bool {
  self.status >= 200 && self.status < 300
}

///|
/// `Content-Type` 是否声明了 SSE（`text/event-stream`）。
///
/// 只做查询：这是给「已经拿到原始流、想知道对面到底是不是 SSE」的调用方自查用的。
/// 真按事件读请改用 `Client::sse`，它在入口处就用同一个判定做了准入检查。
pub fn StreamResponse::is_event_stream(self : StreamResponse) -> Bool {
  @util.declares_event_stream(self.headers)
}

///|
/// 读失败时的统一出口：把传输层错误翻译成 `HttpError`，并把**已经收到的响应**
/// （状态行、响应头，以及 `body` 传进来的字节）挂上去。
///
/// 为什么失败也要挂响应：响应头到手之后才可能开始读，所以失败时状态码与响应头
/// 必然已经存在，它们是回答「是在什么响应上断的」的唯一线索。
/// `body` 只有「读到一半失败、字节还没交出去」的场景（`read_all`）才有值；
/// 按块读失败时数据已经交给调用方了，传 `b""`。
fn StreamResponse::read_error(
  self : StreamResponse,
  error : @transport.TransportError,
  body : Bytes,
) -> HttpError {
  transport_error(
    error,
    self.config,
    Some(
      build_response(
        self.status,
        self.status_text,
        self.headers,
        body,
        self.config,
      ),
    ),
  )
}

///|
/// 读取一段响应体；到 EOF 返回 `None`，此时连接已经关闭。
///
/// 返回的块大小不保证（取决于对端一次发了多少数据），需要按边界切分的
/// 协议请用 `read_until`，不要自己假设一个块就是一条消息。
///
/// 读取失败（超时、断连）时抛 `HttpError`：错误码是传输层的分类，
/// 状态码与响应头挂在 `HttpError::response()` 上。
pub async fn StreamResponse::read_some(
  self : StreamResponse,
  max_len? : Int32,
) -> Bytes? raise HttpError {
  try {
    match max_len {
      Some(limit) => self.body.read_some(max_len=limit)
      None => self.body.read_some()
    }
  } catch {
    // 失败前读到的字节已经交给调用方了，错误里只挂状态行与响应头。
    error => raise self.read_error(error, b"")
  }
}

///|
/// 读到分隔符 `sep` 为止，返回 `sep` 之前的内容（`sep` 被消费掉但不返回）。
///
/// 到 EOF 时把剩余内容当作最后一段返回，再读一次才返回 `None`。
///
/// **不要用它切 SSE 事件**：SSE 允许 CRLF / LF / CR 三种行尾，
/// 拿 `"\n\n"` 当分隔符在 CRLF 流上永远匹配不到（字节里没有连续两个 LF）。
/// 按事件读请改用 `Client::sse`（拿到的是 `SseStream`），
/// 它按规范处理三种行尾；这里刻意不提供事件读取的入口。
pub async fn StreamResponse::read_until(
  self : StreamResponse,
  sep : String,
) -> String? raise HttpError {
  self.body.read_until(sep) catch {
    error => raise self.read_error(error, b"")
  }
}

///|
/// 读到 EOF，返回剩下的全部字节，并关闭流。
///
/// 用于「先拿流判断状态码、再一次性取内容」的场景（例如下载）。
///
/// 中途失败时抛 `HttpError`，并且**已经读到的字节不会丢**：它们与状态行、
/// 响应头一起挂在错误的响应上（`HttpError::response()` 的 `bytes()` / `text()`）
/// ——下载断在 90% 时，这 90% 就是现场。
///
/// 配了 `on_download_progress` 时逐块报告进度（与 `Client::request` 同一条口径：
/// 凡「库读全量」都报告）。按块读的 `read_some` / `read_until` 不报告——
/// 那条路由调用方自己驱动，进度自己累加即可，见 `docs/10-progress.md`。
pub async fn StreamResponse::read_all(
  self : StreamResponse,
) -> Bytes raise HttpError {
  let on_progress = self.config.on_download_progress
  let (bytes, failure) = self.body.read_all_partial(on_progress?)
  match failure {
    Some(error) => raise self.read_error(error, bytes)
    None => bytes
  }
}

///|
/// 关闭响应体流并释放连接。幂等。
///
/// 只读了半截就停止（例如 SSE 收到想结束就断开）时必须显式调用，
/// 否则连接会一直挂着。
pub fn StreamResponse::close(self : StreamResponse) -> Unit {
  self.body.close()
}
