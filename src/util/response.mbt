// util 包的**响应侧**纯函数：响应体解码、Content-Type 判定、状态码放行判定。
// 同样不碰网络与门面类型——「拼成 `Response`」「抛 `HttpError`」都在根包。

///|
/// 按给定的编码把响应体字节解成文本。
///
/// 解码一律是 lossy 的（core 的 `decode_lossy` 系列）：该编码下非法的字节
/// 解成替换字符 `U+FFFD` 而不是抛错。响应正文由服务端说了算，为了几个坏字节
/// 把整个响应判成失败得不偿失；要精确字节读 `Response::bytes()`。
///
/// 只有 `latin1` 是自己写的（core 没有）：ISO-8859-1 的码点就是字节值，
/// 一个循环就够。其余三种都直接调 core。
///
/// 「配置里没写编码时用哪个」不在这里：那是调用方（`Response::text`）的事，
/// 它传 `config.response_encoding.unwrap_or(Utf8)`——与 `defaults()` 里显式
/// 设的默认值一致。本函数只认拿到手的那个编码。
pub fn decode_body(body : Bytes, encoding : ResponseEncoding) -> String {
  match encoding {
    Utf8 => @utf8.decode_lossy(body)
    Latin1 => {
      let buf = StringBuilder()
      for i in 0..<body.length() {
        buf.write_char(body[i].to_char())
      }
      buf.to_string()
    }
    Ascii => @ascii.decode_lossy(body)
    Utf16le => @utf16.decode_lossy(body, endianness=@utf16.Endian::Little)
  }
}

///|
/// 把文本按 **UTF-8** 编成响应体字节，`decode_body` 的反方向。
///
/// 写入方向固定 UTF-8，与请求侧的 `with_data_from_str` 同口径：
/// `response_encoding` 管的是「读出来的文本怎么解」，不管「写进去的文本怎么编」
/// ——一个配置项同时隐式控制两个方向，只会让「换了编码结果对不上」变得难查。
/// 要别的编码，自己编好字节再走 `Response::with_body`。
///
/// 谁在用：`Response::with_text`（响应拦截器改写响应体时）。
pub fn encode_body(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// 响应头里声明的媒体类型：`Content-Type` 去掉 `;` 之后的参数、去掉首尾空白、
/// 小写化。头缺失或值为空时返回 `None`（`Headers::get` 本就大小写不敏感）。
///
/// 只取「媒体类型本体」：`application/json; charset=utf-8` 与 `application/json`
/// 必须得到同一个判断结果。
///
/// 只有 `declares_event_stream` 用它，所以不导出。
fn media_type(headers : Headers) -> String? {
  let raw = match headers.get("Content-Type") {
    Some(value) => value
    None => return None
  }
  // 参数以第一个 `;` 为界，之后的 charset 之类与类型判定无关。
  let essence = match raw.find(";") {
    Some(index) => raw[:index]
    None => raw
  }
  let normalized = essence.trim().to_lower().to_owned()
  if normalized.is_empty() {
    None
  } else {
    Some(normalized)
  }
}

///|
/// 响应头是否声明了 SSE（`text/event-stream`）。
///
/// 判定只有这一处：`StreamResponse::is_event_stream`（给原始流的调用方自查）
/// 与 `Client::sse`（入口处的准入检查）都走它，避免两处规则漂移。
pub fn declares_event_stream(headers : Headers) -> Bool {
  match media_type(headers) {
    Some(media) => media == "text/event-stream"
    None => false
  }
}

///|
/// 状态码是否被配置放行，对应 axios 的 `settle` 判定。
///
/// - `validate_status` 为 `None` 时一律放行（axios 里 `!validateStatus` 的效果）；
/// - 内置默认值是 `200 <= status < 300`，只认 2xx，
///   所以 3xx 也算失败——这与 axios 一致（它不把重定向当成功）。
///
/// 注意判定发生在**自动跟随重定向之后**（跟随在 `client.mbt` 的
/// `Client::send_following_redirects` 里，见 docs/08-redirects.md），
/// 所以走到这里的 3xx 只有两种来源：`max_redirects <= 0` 关掉了跟随，
/// 或者 3xx 没有可用的 `Location`。
///
/// 流式路径（`Client::stream`）复用这个判定：那时响应体还没读，
/// 不能先造出 `Response` 再校验，所以判定本身必须是纯的。
pub fn status_allowed(status : Int, config : Config) -> Bool {
  match config.validate_status {
    None => true
    Some(validate) => validate(status)
  }
}
