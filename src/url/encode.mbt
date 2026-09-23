///|
/// 十六进制大写字母表，用于 `%XX` 转义。
/// 大写是刻意的：`encodeURIComponent` 也输出大写，保持一致才能和 axios 的输出逐字节对齐。
const HEX_UPPER : Bytes = b"0123456789ABCDEF"

///|
/// 该字节是否可以原样保留。
///
/// axios 默认的 `paramsSerializer` 等价于「`encodeURIComponent` 之后再额外转义
/// `! ' ( ) ~`」，所以最终保留下来的字符集恰好是 `A-Za-z0-9-_.*`
/// （`*` 是 `encodeURIComponent` 本来就放过的，且不在额外转义表里）。
///
/// 这与标准库 `@encoding/percent` 的 RFC 3986 规则不同——那里 `~` 保留、`*` 转义、
/// 空格写成 `%20`——所以这里自己实现而不复用标准库，
/// 否则同一个参数在两边会编码出不同的 query string。
fn is_kept(byte : Byte) -> Bool {
  let c = byte.to_char()
  (c >= 'A' && c <= 'Z') ||
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '_' ||
  c == '.' ||
  c == '*'
}

///|
/// 写出 `%XX` 形式的一个字节转义。
fn write_escape(buf : StringBuilder, byte : Int) -> Unit {
  buf.write_char('%')
  buf.write_char(HEX_UPPER[(byte >> 4) & 0x0F].to_char())
  buf.write_char(HEX_UPPER[byte & 0x0F].to_char())
}

///|
/// 把一个 URL 组件（query 的 key 或 value）编码成 axios 兼容的形式。
///
/// 实现要点：
/// - 先经 UTF-8 转成字节再逐字节判断，多字节字符必须按字节逐个转义；
///   如果按 UTF-16 码元处理会把代理对拆错，产生非法编码。
/// - 空格写成 `+` 而不是 `%20`，与 axios 的 `charMap` 以及
///   `application/x-www-form-urlencoded` 的惯例一致。
/// - `[` 与 `]` 会被转义成 `%5B`/`%5D`。这一点常被误解：axios 生成的确实是
///   `tags%5B%5D=a`（见 axios 自己的 buildURL 测试），而不是字面的 `tags[]=a`。
pub fn encode_component(text : StringView) -> String {
  // size_hint 按两倍估：转义后大多数非 ASCII 字符会变成 3 个字节。
  let buf = StringBuilder(size_hint=text.length() * 2)
  for byte in @utf8.encode(text) {
    let code_point = byte.to_char().to_int()
    if is_kept(byte) {
      buf.write_char(byte.to_char())
    } else if code_point == 0x20 {
      buf.write_char('+')
    } else {
      write_escape(buf, code_point)
    }
  }
  buf.to_string()
}
