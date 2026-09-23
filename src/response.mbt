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
