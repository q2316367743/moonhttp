// 配置里的小值类型：认证凭据与响应体解码方式。它们与 Config 拆在不同文件，
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
/// 响应体字节怎么解码成文本，对应 axios 的 `responseEncoding`（默认 `utf-8`）。
///
/// 它只描述「字节 → 文本」这一步：`Response::text()` 就是按它解码出来的字符串，
/// `Response::json()` 也先走这一步、再交给 `@json.parse`。
/// 本项目**不做自动解析**（axios 的 `responseType` / `transformResponse`
/// 没有对应物）：`json()` 必须显式调用，且不拿 `Content-Type` 做判断。
///
/// **这里只描述怎么解码，不描述读不读。** 「读全量还是流」由入口决定：
/// `Client::request` 读全量并交出响应、`Client::stream` 交原始字节流、
/// `Client::sse` 按规范固定 UTF-8 解析事件。所以这个字段只在 `request`
/// 那条路上有落点——流式入口连 `Response` 都没有，解码不是它们的事。
///
/// 解码一律是 lossy 的：遇到该编码下非法的字节用替换字符 `U+FFFD`，
/// 不抛错。响应正文由服务端说了算，为了几个坏字节把整个响应判成失败
/// 得不偿失；要精确字节请读 `Response::bytes()`。
pub(all) enum ResponseEncoding {
  /// 默认：UTF-8
  Utf8
  /// ISO-8859-1：每个字节直接映射成 `U+00XX`，任何字节序列都能解出文本
  Latin1
  /// 只认 `0x00`–`0x7F`，更高的字节是替换字符
  Ascii
  /// UTF-16 小端（axios 里的 `utf16le` / `ucs2`）
  Utf16le
} derive(Eq, Debug)

///|
pub extend ResponseEncoding with Eq::{equal, not_equal}

///|
pub extend ResponseEncoding with @debug.Debug::{to_repr}

///|
/// 渲染成 axios `responseEncoding` 风格的取值，用于 `Config::to_string` 与日志。
pub fn ResponseEncoding::to_string(self : ResponseEncoding) -> String {
  match self {
    Utf8 => "utf-8"
    Latin1 => "latin1"
    Ascii => "ascii"
    Utf16le => "utf-16le"
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
