// 请求头块的渲染（发送侧）。
//
// buffer 的 write_string* 系列写的是 UTF-16LE（终端用途），**不能**用于线协议
// 字节——这里全部走 write_byte / write_bytes，ASCII 直接写码元值，
// 头值里的非 ASCII 按 UTF-8 编码（见 write_field_value 的注释）。

///|
/// 把 ASCII 文本按字节写进缓冲；出现非 ASCII 直接拒绝。
/// 方法、头名、请求目标在线上都必须是 ASCII（is_token 已经保证了方法与头名，
/// 这里是渲染侧的最后防线）。
fn write_ascii(
  buf : @buffer.Buffer,
  text : StringView,
  what : String,
) -> Unit raise ParseError {
  for c in text {
    let code = c.to_int()
    if code > 127 {
      raise ParseError::Malformed("\{what}包含非 ASCII 字符")
    }
    buf.write_byte(code.to_byte())
  }
}

///|
/// 校验请求目标（request-target）：非空、纯 ASCII、不含空白与控制字符。
///
/// 目标来自 `PreparedRequest.url` 的路径段（httpconn 切好交进来），
/// 正常都经过 `@url` 的百分号编码；在这里拒绝的是「用户手拼了含空格 /
/// 含中文的地址」——这类字节进请求行必然拼出坏报文，早失败比晚失败好。
fn validate_target(target : StringView) -> Unit raise ParseError {
  if target.length() == 0 {
    raise ParseError::Malformed("请求目标为空")
  }
  for c in target {
    let code = c.to_int()
    if code <= 32 || code == 127 || code > 127 {
      raise ParseError::Malformed("请求目标包含空白或非 ASCII 字符")
    }
  }
}

///|
/// 校验一个头值：不得含 CR / LF / NUL——头块按行组织，这三个字符任何情况下
/// 都会把值变成新的一行（头注入）。
fn validate_field_value(
  name : StringView,
  value : StringView,
) -> Unit raise ParseError {
  for c in value {
    if c == '\r' || c == '\n' || c.to_int() == 0 {
      raise ParseError::Malformed(
        "头「\{name}」的值包含 CR/LF/NUL（头注入形状）",
      )
    }
  }
}

///|
/// 渲染请求头块：请求行 + 每条头 + 终止空行（RFC 9112 §2），版本固定
/// `HTTP/1.1`——1.0 只在解析侧兼容（docs/17 口径 1：发送侧统一 1.1，
/// 服务器对 1.1 的兼容性远好于反向）。
///
/// 渲染前做完整性校验（这是**最后防线**，不是唯一一道）：
/// - 方法与每个头名必须是 token（自定义方法「存原样发原样」，这一步防的是
///   拼坏请求行；更早的那道闸在 httpconn 建连之前）；
/// - 目标经 `validate_target`；头值经 `validate_field_value`。
///
/// 请求体不在这里：phase 1 请求体一律 `Content-Length` 定长，由 httpconn
/// 渲染完头块后原样写（docs/17 口径 4；chunked 编码留给流式上传那一期）。
pub fn render_request_head(
  meth : StringView,
  target : StringView,
  headers : HeaderMap,
) -> Bytes raise ParseError {
  if !is_token(meth) {
    raise ParseError::Malformed("请求方法不是合法 token：\{meth}")
  }
  validate_target(target)
  let buf = @buffer.Buffer::Buffer(size_hint=128)
  write_ascii(buf, meth, "请求方法")
  buf.write_byte(b' ')
  write_ascii(buf, target, "请求目标")
  write_ascii(buf, " HTTP/1.1\r\n", "版本前缀")
  for entry in headers.entries {
    let (name, value) = entry
    if !is_token(name) {
      raise ParseError::Malformed("头名不是合法 token：\{name}")
    }
    validate_field_value(name, value)
    write_ascii(buf, name, "头名")
    write_ascii(buf, ": ", "头分隔符")
    // 头值允许非 ASCII（obs-text 本来就合法；实践中常有裸 UTF-8 的头值），
    // 按 UTF-8 编成字节——比 latin1 更接近当代服务器的实际行为，
    // 与 docs/15 之外「值是透明字节序列」的口径一致。
    buf.write_bytes(@utf8.encode(value))
    write_ascii(buf, "\r\n", "行尾")
  }
  write_ascii(buf, "\r\n", "头块终止")
  buf.to_bytes()
}
