///|
/// 该字符是否属于 RFC 9110 的 tchar（token 字符集）：
/// `"!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" /
/// "`" / "|" / "~"` 加上 ASCII 字母与数字。
///
/// 方法 token 与头名都只能由它组成——校验它就是防止拼坏请求行的那道闸
/// （自定义方法「存原样发原样」，拼进请求行之前必须过这一关）。
fn is_tchar(c : Char) -> Bool {
  let code = c.to_int()
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) ||
  c == '!' ||
  c == '#' ||
  c == '$' ||
  c == '%' ||
  c == '&' ||
  c == '\'' ||
  c == '*' ||
  c == '+' ||
  c == '-' ||
  c == '.' ||
  c == '^' ||
  c == '_' ||
  c == '`' ||
  c == '|' ||
  c == '~'
}

///|
/// `name` 是否是合法的 token（非空且每个字符都是 tchar）。
///
/// 只认 ASCII：非 ASCII 字符（比如中文）不是 token 字符，直接判非法——
/// 方法与头名在线上必须是 ASCII，宽进只会把错误推迟到服务器侧才暴露。
pub fn is_token(name : StringView) -> Bool {
  if name.length() == 0 {
    return false
  }
  for c in name {
    if !is_tchar(c) {
      return false
    }
  }
  true
}
