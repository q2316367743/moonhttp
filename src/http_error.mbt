// ============================================================================
// 根包的错误契约：`ErrorCode` / `ErrorInfo` / `HttpError`，以及**所有**构造它们的地方。
//
// 本文件与 `facade.mbt` / `client.mbt` 同目录，也就是**同一个包**：类型互相引用、
// 包私有的 `fn` 互相调用都不受任何限制，拆文件只影响阅读，不影响依赖方向。
// （跨包就不是这样了：门面类型搬出根包会成环，`HttpError` 离开根包更会让
// `catch { @moonhttp.HttpError(info) }` 失效，理由见 `docs/01-architecture.md`。）
//
// 分区（顺序无关，用区块注释标出）：
//   1. ErrorCode      —— 错误分类与 axios 风格错误码字符串
//   2. ErrorInfo      —— 详细信息（message / code / config / response）
//   3. HttpError      —— 对外错误类型、访问器与构造器
//   4. 抛错点          —— 传输层翻译、状态码分档与校验
// ============================================================================

// ---------------------------------------------------------------------------
// 1. ErrorCode —— 错误分类
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
  /// 重定向次数超过 `max_redirects`：多半是重定向成环，或上限设得太小
  TooManyRedirects
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
///
/// 重定向上限用 `ERR_FR_TOO_MANY_REDIRECTS`：这是 axios 透传的
/// follow-redirects 错误码（axios 自己也定义了 `AxiosError.ERR_FR_TOO_MANY_REDIRECTS`
/// 这个常量），跟着用同一个字符串，调用方按码分支时不必区分是哪一家的实现。
pub fn ErrorCode::to_string(self : ErrorCode) -> String {
  match self {
    BadRequest => "ERR_BAD_REQUEST"
    BadResponse => "ERR_BAD_RESPONSE"
    Network => "ERR_NETWORK"
    Timeout => "ECONNABORTED"
    InvalidUrl => "ERR_INVALID_URL"
    NotSupported => "ERR_NOT_SUPPORT"
    TooManyRedirects => "ERR_FR_TOO_MANY_REDIRECTS"
  }
}

///|
/// 渲染与 `ErrorCode::to_string` 一致，这样 `"\{code}"` 直接给出 axios 风格错误码。
pub impl Show for ErrorCode with fn to_string(self) {
  self.to_string()
}

///|
pub extend ErrorCode with Show::{output}

// ---------------------------------------------------------------------------
// 2. ErrorInfo —— 错误的详细信息
// ---------------------------------------------------------------------------

///|
/// 错误的详细信息，对应 `AxiosError` 上的 `message` / `code` / `config` / `response`。
pub(all) struct ErrorInfo {
  /// 面向人的错误描述
  message : String
  code : ErrorCode
  /// 触发这次错误的配置（**已完成合并**），便于定位到底是哪一项配置不对
  config : Config
  /// 服务端已经返回的响应：
  ///
  /// - 状态码没通过校验时：完整响应（两个流式入口会把错误体读完再抛）；
  /// - 传输层失败（超时、断连）发生在响应头到手之后时：失败前已经收到的部分
  ///   ——状态行与响应头一定在，响应体字节可能只有半截（`read_all` 中途失败时
  ///   就是已经读到的那部分，`bytes()` / `text()` 拿到的就是它）；
  /// - 连响应头都没收到就失败（连不上、DNS 失败、请求没发出去）：`None`。
  response : Response?
}

// ---------------------------------------------------------------------------
// 3. HttpError —— 对外错误类型、访问器与构造器
// ---------------------------------------------------------------------------

///|
/// 本模块对外的错误类型。
///
/// 用 `pub(all) suberror` 而不是 `pub suberror`：后者不导出构造子，
/// 使用方就只能拿到错误、无法按分类匹配。这里刻意把构造子放开，
/// 让调用方能写 `catch { @moonhttp.HttpError(info) => ... }`。
///
/// 构造子必须定义在根包：`pub using` 能再导出类型，但**再导出不了错误构造子**，
/// 所以 `HttpError` 一旦搬进子包，上面那种解构写法就失效了（实测证据见
/// `docs/01-architecture.md`）。本文件在根包里拆出来，不影响这一点。
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
/// 错误里带的响应：
///
/// - 状态码没通过校验时是完整响应；
/// - 传输层失败（超时、断连）发生在响应头到手之后时，是失败前已经收到的部分
///   ——响应体字节可能只有半截（`bytes()` / `text()` 拿到的就是那半截）；
/// - 连响应头都没收到时为 `None`。
pub fn HttpError::response(self : HttpError) -> Response? {
  self.info().response
}

///|
/// 触发这次错误的配置（已完成合并）。
pub fn HttpError::config(self : HttpError) -> Config {
  self.info().config
}

///|
/// 直接构造一个不带响应的 `HttpError`。
///
/// 这是 `ErrorInfo` 的公开入口：包外的代码此前只能读错误、不能造错误，而
/// **请求拦截器需要造**——它主动中止请求时就得抛一个错误出去，见
/// `docs/11-interceptors.md`：
///
/// ```moonbit nocheck
/// .use_request(config => {
///   if token == "" {
///     raise @moonhttp.HttpError::new("缺少 token", @moonhttp.ErrorCode::BadRequest, config)
///   }
///   config.with_header("Authorization", token)
/// })
/// ```
///
/// `code` 由调用方按语义选。客户端侧拒绝请求（缺凭据、参数不合法）建议用
/// `ErrorCode::BadRequest`：axios 在同样的位置上用的也是 `ERR_BAD_REQUEST`
/// （它同时覆盖「4xx 响应」与「请求本身不合法」两种情况）。
///
/// 错误里没有响应（`response()` 返回 `None`）：这次请求根本没发出去。
/// 要把某个响应挂上去，用 `ErrorInfo` 字面量自己造。
pub fn HttpError::new(
  message : String,
  code : ErrorCode,
  config : Config,
) -> HttpError {
  HttpError({ message, code, config, response: None, })
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

// ---------------------------------------------------------------------------
// 4. 抛错点 —— 传输层失败、状态码失败与重定向上限都从这里出去
//    （「状态码是否放行」这个判定本身是纯函数，在 util/response.mbt）
// ---------------------------------------------------------------------------

///|
/// 把传输层错误翻译成对外的 `HttpError`。
///
/// 这层翻译的意义是：调用方不需要认识 `moonbitlang/async` 的错误类型，
/// 也不必知道底层用的是哪套 HTTP 实现。流式读取失败走的是同一条映射。
///
/// `response` 是**失败前已经收到的响应**：传输层失败不等于「什么都没收到」
/// ——响应头到手之后才失败的请求，状态行、响应头与已经读到的字节都在手里
/// （`bytes()` / `text()` 拿到的可能是半截），把它们挂到错误上，失败现场
/// 才不会只剩一个错误码。
/// 失败发生在收到响应头之前（连不上、DNS 解析失败、请求还没发出去）时传
/// `None`——那时确实没有响应。
///
/// 错误码仍然是「失败本身」的分类（超时归 `Timeout`、断连归 `Network`），
/// 不会因为挂上了响应就改用状态码分档。
fn transport_error(
  error : @transport.TransportError,
  config : Config,
  response : Response?,
) -> HttpError {
  match error {
    @transport.TransportError::Timeout =>
      make_error("请求超时", ErrorCode::Timeout, config, response)
    @transport.TransportError::Network(message) =>
      make_error(
        "网络请求失败：" + message,
        ErrorCode::Network,
        config,
        response,
      )
    @transport.TransportError::Unsupported(message) =>
      make_error(
        "传输层不支持该请求：" + message,
        ErrorCode::NotSupported,
        config,
        response,
      )
  }
}

///|
/// 校验失败时按 axios 的分档给错误码：4xx → `BadRequest`，其余 → `BadResponse`
/// （axios 用 `[ERR_BAD_REQUEST, ERR_BAD_RESPONSE][floor(status/100) - 4]` 取到同一结果）。
fn status_error_code(status : Int) -> ErrorCode {
  if status >= 400 && status < 500 {
    ErrorCode::BadRequest
  } else {
    ErrorCode::BadResponse
  }
}

///|
/// 状态码不被放行时的统一错误。两条路径（读全量 / 流式）共用同一份文案与分档。
///
/// 响应是必有的：读全量路径此时已经解析出响应，流式路径也把错误体读完了
/// （哪怕只读到一部分，状态行与响应头一定在）。所以这里不收 `None`——
/// 「状态码失败」和「错误里带响应」是同一件事。
fn status_error(
  status : Int,
  config : Config,
  response : Response,
) -> HttpError {
  make_error(
    "请求失败，状态码 " + status.to_string(),
    status_error_code(status),
    config,
    Some(response),
  )
}

///|
/// 重定向次数超过上限时的统一错误（`Client::request` 的重定向循环里抛）。
///
/// `response` 是**最后那个 3xx 响应**：读到它时说明重定向又来了一个，
/// 只是预算已经用完。按本项目「失败时带上已经收到的响应」的规则
/// （见 docs/README.md 的同步清单第 8 条）把它挂上——跟到第几跳、
/// 对面给的 `Location` 是什么，正是排查重定向成环最需要的信息。
/// 这一点与 axios 不同：axios 的这个错误里没有响应（follow-redirects
/// 在跟随下一跳前就把 3xx 响应 destroy 掉了），差异见 docs/08-redirects.md。
fn too_many_redirects_error(
  max_redirects : Int,
  config : Config,
  response : Response?,
) -> HttpError {
  make_error(
    "重定向次数超过上限：max_redirects = " + max_redirects.to_string(),
    ErrorCode::TooManyRedirects,
    config,
    response,
  )
}

///|
/// 校验响应状态码；不通过就抛出带响应的错误。
fn validate_response(response : Response) -> Unit raise HttpError {
  if !@util.status_allowed(response.status, response.config) {
    raise status_error(response.status, response.config, response)
  }
}
