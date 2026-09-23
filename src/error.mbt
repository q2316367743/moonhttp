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
/// 让调用方能写 `catch { @easy-http-client.HttpError(info) => ... }`。
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
