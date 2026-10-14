// ============================================================================
// http_error 包：对外的错误契约——`ErrorCode` / `ErrorInfo` / `HttpError`，
// 以及全部访问器。
//
// 本包是**纯契约**：只定义错误长什么样，不定义「什么情况下造错误」。
// 所有构造错误的动作（传输层翻译、状态码分档、重定向超限、取消归一、
// 状态码校验）都在 `client` 包——构造是编排层的行为，不是契约的一部分。
// 这样分工让本包不依赖 `transport`，`HttpError` 也不会在别处被造出
// 不一致的形状；`HttpError::new` 是唯一的公开构造口（给请求拦截器
// 主动中止请求用的，见 `docs/11-interceptors.md`）。
//
// 与根包的关系：根包用 `pub using` 把三个类型再导出给使用者，使用方仍然
// 只 import 一个 `@moonhttp`。`pub using` 能再导出类型，但**再导出不了
// 构造器**（当前工具链实测，证据见 `docs/01-architecture.md`），所以
// 使用方的构造器模式要写类型限定的形式：
//
//   catch { @moonhttp.HttpError::HttpError(info) => ... }
//
// 类型注解、方法调用（`error.code()` 等）与 `raise @moonhttp.HttpError`
// 签名都不受影响；本包内部的模式匹配不受影响（构造器在自己包里是裸的）。
//
// 分区（顺序无关，用区块注释标出）：
//   1. ErrorCode      —— 错误分类与 axios 风格错误码字符串
//   2. ErrorInfo      —— 详细信息（message / code / config / response）
//   3. HttpError      —— 对外错误类型、访问器与公开构造器
// ============================================================================

///|
/// 包内别名：裸名 `Config` / `Response` 来自下面两个包
/// （根包会对使用者再导出它们，本包内部按裸名使用）。
using @config {type Config}

///|
using @response {type Response}

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
  /// 被取消信号叫停：调用方主动中止，不是网络故障
  Cancelled
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
/// 取消用的是 `ERR_CANCELED`（axios 的 `AxiosError.ERR_CANCELED`，也是
/// 它 `CanceledError` 上的 `code`）；与超时分开，调用方才能把「用户主动中止」
/// 与「超时兜底」区分对待——前者通常不该重试，也不该报给用户。
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
    Cancelled => "ERR_CANCELED"
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
// 3. HttpError —— 对外错误类型、访问器与公开构造器
// ---------------------------------------------------------------------------

///|
/// 本模块对外的错误类型。
///
/// 用 `pub(all) suberror` 而不是 `pub suberror`：后者不导出构造子，
/// 使用方就只能拿到错误、无法按分类匹配。这里刻意把构造子放开，
/// 让调用方能写 `catch { @moonhttp.HttpError::HttpError(info) => ... }`
/// ——构造器不做包限定裸写不出来（`pub using` 再导出不了构造器，
/// 实测证据见 `docs/01-architecture.md`），类型限定的写法不受影响。
///
/// 同理，`client` 包的抛错点也靠 `pub(all)` 跨包构造本类型。
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
/// 这次失败是不是被取消（对应 axios 的 `axios.isCancel`）。
///
/// 等价于 `error.code() is ErrorCode::Cancelled`，存在的意义是让调用点读起来
/// 与 axios 的写法一致，也避免每次手写模式匹配。取消来自调用方自己的
/// `AbortController`（不是超时、不是网络错误），通常该安静地收场而不是报错。
///
/// ```moonbit nocheck
/// client.request(config) catch {
///   error if error.is_cancelled() => println("已取消：" + error.message())
///   error => println(error.to_string())
/// }
/// ```
pub fn HttpError::is_cancelled(self : HttpError) -> Bool {
  self.code() is ErrorCode::Cancelled
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
