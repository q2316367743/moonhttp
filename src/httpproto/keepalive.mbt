// 连接复用判定（RFC 9112 §9.3 / §9.6 的客户端侧规则）：一份响应结束后，
// 这条连接还能不能原样服务下一个请求。这里只回答「服务端允不允许」；
// 「响应体消费完才回池」「取消 = 毒化」等池契约的执行在 httpconn
// （docs/17 口径 4、docs/21）。

///|
/// 判定「这份响应」结束后连接能否复用。
///
/// - HTTP/1.1：持久连接是默认，只有 `Connection` 头里出现 `close` token 才关闭；
/// - HTTP/1.0：默认非持久，必须显式出现 `keep-alive` token 服务端才会保持连接；
/// - `close` 与 `keep-alive` 并存的矛盾声明按保守处理：关闭。
///
/// `Connection` 头是逗号列表（RFC 9110 §7.6.1），token 出现在列表任意位置、
/// 或出现在任意一条同名头里都算数；头缺失按「无声明」走各版本的默认。
/// 分帧维度（UntilClose 的响应体以关闭收尾、天然不可复用）不在本函数的
/// 职责内——那是 httpconn 拿着 `body_framing` 的结果一起判的。
pub fn connection_reusable(version : HttpVersion, headers : HeaderMap) -> Bool {
  let mut close = false
  let mut keep_alive = false
  for value in headers.get_all("Connection") {
    if contains_token(value, "close") {
      close = true
    }
    if contains_token(value, "keep-alive") {
      keep_alive = true
    }
  }
  match version {
    HttpVersion::Http11 => !close
    HttpVersion::Http10 => keep_alive && !close
  }
}

///|
/// 请求方的 `Connection` 头是否声明了 `close`。连接池据此执行「请求方
/// 自己要关的连接，响应结束后不回池」（逐请求禁复用的出口）。
pub fn declares_close(connection_header : String) -> Bool {
  contains_token(connection_header, "close")
}

///|
/// 头值（逗号列表）里是否出现某个 token（大小写不敏感、两侧容忍 OWS）。
fn contains_token(value : String, want : String) -> Bool {
  for piece in value.split(",") {
    if piece.to_owned().trim(chars=" \t").to_owned().to_lower() == want {
      return true
    }
  }
  false
}
