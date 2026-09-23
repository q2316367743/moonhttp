// 配置里的小值类型：认证凭据与响应体处理方式。它们与 Config 拆在不同文件，
// 便于各自独立演进（也满足 AGENTS.md RL-04 的 300 行上限）。

///|
/// `Authorization: Basic ...` 用的凭据。
///
/// 两个字段都是 `Option`，所以它的合并是逐字段的深合并：
/// 默认值只给了 `username`、请求只给了 `password`，合并后两者都在。
/// 这正是 axios `mergeDeepProperties` 对普通对象（plain object）的处理方式。
pub(all) struct Auth {
  username : String?
  password : String?
} derive(Eq, Default, Debug)

///|
pub extend Auth with Eq::{equal, not_equal}

///|
pub extend Auth with Default::{default}

///|
pub extend Auth with @debug.Debug::{to_repr}

///|
/// 响应体的解码方式，对应 axios 的 `responseType` 加上 `forcedJSONParsing`。
///
/// axios 的默认值是 `undefined` + `forcedJSONParsing: true`，
/// 也就是「不特别指定类型，但只要看起来像 JSON 就自动解析」，
/// 本项目把它显式化为 `Auto`，并且把「看起来像 JSON」落到 `Content-Type` 上
/// （判定规则见 `auto_parses_json`）。
///
/// **这里只描述「读完的响应体怎么解码」，不描述读不读。**
/// 「读完还是流」由入口决定：`Client::request` 读全、`Client::stream` 不读、
/// `Client::sse` 按事件读。所以这里没有 `Stream` 这样的取值——
/// 想让配置也表达「不要读全」，在静态类型下既没有落点，也会把
/// 「解码方式」和「返回形态」两件事混在一起。
pub(all) enum ResponseType {
  /// 默认：`Content-Type` 是 JSON（或没声明）时尝试按 JSON 解析，
  /// 失败就把原文当作字符串；声明为其它类型则完全不解析
  Auto
  /// 强制按 JSON 解析，忽略 `Content-Type`；
  /// 解析失败会作为错误抛出（对应 axios 的 ERR_BAD_RESPONSE）
  Json
  /// 完全不解析，`Response::data` 就是 `Json::String(原文)`
  Text
} derive(Eq, Debug)

///|
pub extend ResponseType with Eq::{equal, not_equal}

///|
pub extend ResponseType with @debug.Debug::{to_repr}

///|
/// 渲染成小写的配置值，用于 `Config::to_string` 与日志。
pub fn ResponseType::to_string(self : ResponseType) -> String {
  match self {
    Auto => "auto"
    Json => "json"
    Text => "text"
  }
}

///|
/// 渲染认证信息：用户名照常显示，密码一律替换成 `<redacted>`。
///
/// 配置经常整体进日志或断言失败信息，明文打印密码会把凭据泄漏到
/// 日志文件与 CI 输出里，所以这里主动脱敏。
pub fn Auth::to_string(self : Auth) -> String {
  let buf = StringBuilder()
  let mut first = true
  match self.username {
    Some(username) => first = push_field(buf, first, "username", username)
    None => ()
  }
  match self.password {
    Some(_) => first = push_field(buf, first, "password", "<redacted>")
    None => ()
  }
  render_braced("Auth", buf.to_string(), first)
}
