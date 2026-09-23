// ============================================================================
// AGENTS.md RL-04 例外声明
//
// 本文件是根包的**门面层**：对外暴露的数据类型与再导出集中在这里。
// 它超过 RL-04 的 300 行上限（452 行），按 RL-04 为「根包文件」开出的例外
// 处理——上限 1000 行，并在此声明。
//
// 为什么这几个类型在同一个文件：它们互相引用——`HttpError` 要带 `Response`
// （失败时把响应挂在错误上），两个流式类型要抛 `HttpError`。拆成多个文件不会
// 减少这层耦合，只增加跳转成本；拆成多个**包**更不行，MoonBit 不允许包间循环依赖。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   1. 再导出           —— pub using 各子包的类型
//   2. Response         —— 读全量得到的响应
//   3. StreamResponse   —— 原始字节流响应（下载）
//   4. SseStream        —— 按事件读的 SSE 响应
//   5. HttpError        —— 错误分类、详细信息与访问器
// ============================================================================

// ---------------------------------------------------------------------------
// 1. 再导出 —— 各子包里有意义的类型
// ---------------------------------------------------------------------------

///|
/// 门面：把子包里对使用者有意义的类型从根包再导出一份。
///
/// 这样开发者只 import 一个 `@moonhttp` 就能拿到全部公开类型，
/// 不必记住每个类型归属哪个子包。子包结构本身仍然保留，
/// 需要精细控制的使用者（例如自己实现 `Transport`）可以直接依赖对应子包。
///
/// 约定：凡是出现在公开签名里的类型，都在定义它的包里再导出一次，
/// 因此各层之间不会出现「要用这个 API 却不知道类型该从哪 import」的情况。
pub using @config {type Config, type Method, type Auth, type ResponseType}

///|
pub using @headers {type Headers}

///|
/// SSE 解析器也再导出：它是独立的纯逻辑包，既能被 `Client::sse` 驱动，
/// 也能用在别的字节来源上（文件、WebSocket），是「服务端不声明
/// `text/event-stream` 时自己接」的公开逃生口。
pub using @sse {type SseEvent, type SseParser}

///|
/// 传输层抽象也一并再导出：自定义传输实现是公开的扩展点。
pub using @transport {trait Transport}

// ---------------------------------------------------------------------------
// 2. Response —— 做完解码的响应对象
// ---------------------------------------------------------------------------

///|
/// 对外的响应对象，对应 axios 的 `AxiosResponse`。
pub(all) struct Response {
  /// 按 `response_type` 处理过的响应体。
  ///
  /// - `Auto` / `Json`：JSON 解析成功的对象；
  /// - `Auto` 下解析失败、或 `response_type` 为 `Text` 时：
  ///   原始文本包成 `Json::String`（对应 axios 的 `forcedJSONParsing` 行为——
  ///   解析失败不报错，把字符串原样交给调用方）；
  /// - 需要二进制内容时读 `raw`。
  data : Json
  /// HTTP 状态码
  status : Int
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**），与 axios 的 `response.config` 一致
  config : Config
  /// 未经解析的原始响应体字节
  raw : Bytes
} derive(Debug)

///|
pub extend Response with @debug.Debug::{to_repr}

///|
/// 响应体的文本形式：直接对原始字节做 UTF-8 解码，不做 JSON 解析。
///
/// 用 `decode_lossy` 而不是 `decode`：响应体未必是合法 UTF-8
/// （可能是二进制或其它编码），这里返回带替换字符的文本比直接抛错更有用；
/// 需要精确字节时读 `raw`。
pub fn Response::text(self : Response) -> String {
  @utf8.decode_lossy(self.raw)
}

///|
/// 状态码是否落在 2xx。
///
/// 注意这与「请求是否成功」不是一回事：`request` 只在校验规则放行时才返回响应，
/// 所以能拿到 `Response` 通常已经表示成功；这个方法是给
/// 自定义了 `validate_status`（放行了 3xx/4xx）的场景用的。
pub fn Response::is_success(self : Response) -> Bool {
  self.status >= 200 && self.status < 300
}

///|
/// 响应体的字节长度。
pub fn Response::content_length(self : Response) -> Int {
  self.raw.length()
}
// ---------------------------------------------------------------------------
// 3. StreamResponse —— 原始字节流响应（下载）
// ---------------------------------------------------------------------------

///|
/// 流式响应：状态行与响应头已经到手，响应体按需读取。
///
/// 这是**原始字节流**的入口（下载、边到边处理都走它）。按事件读 SSE
/// 是另一种协议，用 `Client::sse` 拿到的 `SseStream`——两边类型分开，
/// 「按块读」与「按事件读」各自只有一个入口，调错是编译错误而不是
/// 把二进制数据解成一堆无意义的事件。
///
/// 与 `Response` 的差别都由「响应体还没读」这一条派生出来：
/// - 没有 `data`：响应体可能无限长，没法用 `Json` 表示；
/// - 没有 `raw`：字节还没读出来，需要时用 `read_all()` 取；
/// - 读取随时可能失败：统一抛 `HttpError`，调用方不必认识传输层错误。
///
/// 状态码与响应头这些「不读 body 就能拿到」的信息与 `Response` 保持一致，
/// 所以拿到流之后可以先按状态码与 `Content-Type` 决定怎么读。
pub(all) struct StreamResponse {
  /// HTTP 状态码
  status : Int
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
  declares_event_stream(self.headers)
}

///|
/// 读取一段响应体；到 EOF 返回 `None`，此时连接已经关闭。
///
/// 返回的块大小不保证（取决于对端一次发了多少数据），需要按边界切分的
/// 协议请用 `read_until`，不要自己假设一个块就是一条消息。
pub async fn StreamResponse::read_some(
  self : StreamResponse,
  max_len? : Int,
) -> Bytes? raise HttpError {
  try {
    match max_len {
      Some(limit) => self.body.read_some(max_len=limit)
      None => self.body.read_some()
    }
  } catch {
    error => raise transport_error(error, self.config)
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
    error => raise transport_error(error, self.config)
  }
}

///|
/// 读到 EOF，返回剩下的全部字节，并关闭流。
///
/// 用于「先拿流判断状态码、再一次性取内容」的场景（例如下载）。
pub async fn StreamResponse::read_all(
  self : StreamResponse,
) -> Bytes raise HttpError {
  self.body.read_all() catch {
    error => raise transport_error(error, self.config)
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
// ---------------------------------------------------------------------------
// 4. SseStream —— 按事件读的 SSE 响应
// ---------------------------------------------------------------------------

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
pub(all) struct SseStream {
  /// HTTP 状态码
  status : Int
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**）
  config : Config
  /// 响应体流。字段私有：`next_event` 是唯一的读取入口，
  /// 这样错误才能统一映射成 `HttpError`，也不会有人绕过解析器去读字节。
  priv body : @transport.ResponseBody
  /// 事件解析器的状态
  priv parser : @sse.SseParser
  /// 调用方是否已经 `close()`。
  ///
  /// 单靠关掉 `body` 不够：一次读取可能已经把好几个事件解析进了解析器的队列，
  /// 关掉连接之后它们照样取得出来。`close` 的语义是「到此为止」，
  /// 与 `StreamResponse::close()` 之后 `read_some` 只返回 `None` 保持一致。
  priv mut closed : Bool
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
/// 读下一个事件；流结束返回 `None`。
///
/// 事件边界、字段语义（`event:` / `data:` / `id:` / `retry:`）、注释行、
/// 多行 `data:` 合并、三种行尾都由 `@sse.SseParser` 按 WHATWG 规范处理，
/// 调用方拿到的已经是解析好的事件。
///
/// 几条与规范一致的边界：
/// - 只发了 `id:` / `retry:` 或只有心跳注释的块**不产生事件**，会继续往下读；
/// - 流结束时没等到空行的事件**丢弃**，不会补发半个事件；
/// - `close()` 之后一律返回 `None`；
/// - `SseEvent` 上的 `id` / `retry` 是解析器的持久状态快照，
///   断线重连要用它们（本项目不自动重连，重连逻辑写在上层）。
pub async fn SseStream::next_event(
  self : SseStream,
) -> @sse.SseEvent? raise HttpError {
  // 已经关掉的流不再吐事件：解析器的队列里可能还存着已经解出来的事件，
  // 但 `close` 就是「到此为止」。
  if self.closed {
    return None
  }
  // 先取已解析好的（一次读进来的字节可能带来多个事件），没有再读一块喂进去。
  let mut event = self.parser.next()
  while event is None {
    let chunk = self.body.read_some() catch {
      error => raise transport_error(error, self.config)
    }
    match chunk {
      None => {
        // EOF：让解析器处理末尾那个卡住的 CR，之后丢弃未完成的事件。
        self.parser.finish()
        return self.parser.next()
      }
      Some(bytes) => {
        self.parser.push(bytes)
        event = self.parser.next()
      }
    }
  }
  event
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
// ---------------------------------------------------------------------------
// 5. HttpError —— 错误分类、详细信息与访问器
// ---------------------------------------------------------------------------

///|
/// 错误的分类，对应 axios 的 `AxiosError.code`。
///
/// 分成这几档是为了让调用方能按「该怎么处理」分支：
/// 超时可以重试，网络失败要看连接，4xx 要看自己的请求参数，
/// 5xx 要等服务端恢复。
pub(all) enum ErrorCode {
  /// 4xx：请求本身有问题（参数、权限、资源不存在等）
  BadRequest
  /// 5xx，以及被校验规则拒绝的其它状态码：服务端没有正常完成请求
  BadResponse
  /// 网络层失败：连接失败、DNS 解析失败、TLS 握手失败等
  Network
  /// 超时
  Timeout
  /// url 缺失或非法
  InvalidUrl
  /// 本地就失败了：配置有误，或用了传输层不支持的能力
  NotSupported
} derive(Eq, Debug)

///|
pub extend ErrorCode with Eq::{equal, not_equal}

///|
pub extend ErrorCode with @debug.Debug::{to_repr}

///|
/// 渲染成 axios 风格的错误码字符串（即 `AxiosError.code` 的取值）。
///
/// 超时用的是 `ECONNABORTED` 而不是 `ETIMEDOUT`：axios 默认就是前者，
/// 只有在打开 `transitional.clarifyTimeoutError` 时才会改用后者。
pub fn ErrorCode::to_string(self : ErrorCode) -> String {
  match self {
    BadRequest => "ERR_BAD_REQUEST"
    BadResponse => "ERR_BAD_RESPONSE"
    Network => "ERR_NETWORK"
    Timeout => "ECONNABORTED"
    InvalidUrl => "ERR_INVALID_URL"
    NotSupported => "ERR_NOT_SUPPORT"
  }
}

///|
/// 渲染与 `ErrorCode::to_string` 一致，这样 `"\{code}"` 直接给出 axios 风格错误码。
pub impl Show for ErrorCode with fn to_string(self) {
  self.to_string()
}

///|
pub extend ErrorCode with Show::{output}

///|
/// 错误的详细信息，对应 `AxiosError` 上的 `message` / `code` / `config` / `response`。
pub(all) struct ErrorInfo {
  /// 面向人的错误描述
  message : String
  code : ErrorCode
  /// 触发这次错误的配置（**已完成合并**），便于定位到底是哪一项配置不对
  config : Config
  /// 服务端已经返回、但没通过状态码校验时，原始响应挂在这里
  response : Response?
}

///|
/// 本模块对外的错误类型。
///
/// 用 `pub(all) suberror` 而不是 `pub suberror`：后者不导出构造子，
/// 使用方就只能拿到错误、无法按分类匹配。这里刻意把构造子放开，
/// 让调用方能写 `catch { @moonhttp.HttpError(info) => ... }`。
pub(all) suberror HttpError {
  HttpError(ErrorInfo)
}

///|
/// 取出错误的详细信息。
pub fn HttpError::info(self : HttpError) -> ErrorInfo {
  match self {
    HttpError(info) => info
  }
}

///|
/// 错误的分类。
pub fn HttpError::code(self : HttpError) -> ErrorCode {
  self.info().code
}

///|
/// 错误的文字描述。
pub fn HttpError::message(self : HttpError) -> String {
  self.info().message
}

///|
/// 没通过状态码校验时的原始响应；其它情况为 `None`。
pub fn HttpError::response(self : HttpError) -> Response? {
  self.info().response
}

///|
/// 触发这次错误的配置（已完成合并）。
pub fn HttpError::config(self : HttpError) -> Config {
  self.info().config
}

///|
/// 渲染成 `错误码: 描述` 的形式，便于日志与断言。
pub fn HttpError::to_string(self : HttpError) -> String {
  let info = self.info()
  info.code.to_string() + ": " + info.message
}

///|
/// 渲染与 `HttpError::to_string` 一致，便于日志与字符串插值。
pub impl Show for HttpError with fn to_string(self) {
  self.to_string()
}

///|
pub extend HttpError with Show::{output}

///|
/// 统一构造 `HttpError`，避免每处都手写一遍 `ErrorInfo`。
/// 调用点用 `raise make_error(...)` 抛出。
fn make_error(
  message : String,
  code : ErrorCode,
  config : Config,
  response : Response?,
) -> HttpError {
  HttpError(ErrorInfo::{ message, code, config, response, })
}
