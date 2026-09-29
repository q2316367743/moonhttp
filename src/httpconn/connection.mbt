// 连接的封装与拨号：把「一条能读写的线」从 TCP / TLS / CONNECT 隧道三种
// 来手里统一起来。
//
// Connection 实现 `@io.Reader + @io.Writer`，所以它能直接交给 `Tls::client`
// 做 TLS 升级（隧道上 HTTPS 与直连 HTTPS 走同一条代码），也能交给
// `ResponseBody::open_wire` 当响应体来源。pushback 用 `ReaderBuffer`：
// 读状态行/头块的「多读一个字节」都留在缓冲里，进 body 阶段不丢。

///|
/// 线路本体：裸 TCP 或 TLS（TLS 的内层可以是 TCP，也可以是隧道）。
priv enum Wire {
  Plain(@socket.Tcp)
  Secure(@tls.Tls)
}

///|
/// 一条已建立（或已升级）的连接。
priv struct Connection {
  stream : Wire
  buf : @io.ReaderBuffer
}

///|
/// 从一条裸 TCP 连接开始。
fn Connection::wrap(tcp : @socket.Tcp) -> Connection {
  { stream: Plain(tcp), buf: @io.ReaderBuffer::new(), }
}

///|
/// 在当前线路上叠 TLS（直连 HTTPS、或 CONNECT 隧道上的 HTTPS 都走这里）。
/// TLS 握手受外层的 `timeout` 约束——它在 `send_head` 的 attempt 闭包里发生。
/// 消费当前连接并给出一条新连接：升级点之前不会有多读的字节
/// （头块读取都发生在响应阶段），新缓冲从零开始。
async fn Connection::upgrade_tls(
  self : Connection,
  host : String,
) -> Connection {
  let tls = @tls.Tls::client(self, host~)
  { stream: Secure(tls), buf: @io.ReaderBuffer::new(), }
}

///|
/// 关闭连接。TLS 的 close 同步完成；重复关闭由各层自行幂等。
fn Connection::close(self : Connection) -> Unit {
  match self.stream {
    Plain(tcp) => tcp.close()
    Secure(tls) => tls.close()
  }
}

///|
/// 写一段字节到线上（请求头块与请求体都走它）。
async fn Connection::write(self : Connection, data : &@io.Data) -> Unit {
  match self.stream {
    Plain(tcp) => tcp.write(data)
    Secure(tls) => tls.write(data)
  }
}

///|
/// `@io.Reader` 实现：内部缓冲即 pushback。
/// extend 声明让 read / read_until 可以按方法形式调用（否则是弃用告警的
/// 隐式提升；@io.Writer 的默认方法没有用到，不需要列）。
extend Connection with @io.Reader::{read, read_until}

///|
impl @io.Reader for Connection with fn _get_internal_buffer(self : Connection) -> @io.ReaderBuffer {
  self.buf
}

///|
/// 从线路上直接读一段（0 = EOF）。默认方法（read / read_until / …）
/// 会先消费 pushback 再落到这里。
impl @io.Reader for Connection with fn _direct_read(
  self : Connection,
  dst : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  match self.stream {
    Plain(tcp) => tcp.read(dst, offset~, max_len~)
    Secure(tls) => tls.read(dst, offset~, max_len~)
  }
}

///|
/// `@io.Writer` 实现：只为满足 `Tls::client` 对「Reader + Writer」的要求，
/// 写路径不经过任何缓冲。
impl @io.Writer for Connection with fn write_once(
  self : Connection,
  data : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  match self.stream {
    Plain(tcp) => tcp.write_once(data, offset~, len~)
    Secure(tls) => tls.write_once(data, offset~, len~)
  }
}

///|
/// 拨号到请求目标：直连（TCP / TLS）或经代理（CONNECT 隧道 + TLS）。
async fn dial(
  target : Target,
  proxy : @transport.ProxyEndpoint?,
) -> Connection raise @transport.TransportError {
  match proxy {
    None => {
      let conn = connect_tcp(target.host, target.port)
      if target.use_tls {
        conn.upgrade_tls(target.host) catch {
          error => raise @transport.TransportError::Network(error.to_string())
        }
      } else {
        conn
      }
    }
    Some(endpoint) => dial_via_proxy(target, endpoint)
  }
}

///|
/// 建立 TCP 连接；DNS 解析失败、拒绝连接都归 `Network`。
async fn connect_tcp(
  host : String,
  port : Int,
) -> Connection raise @transport.TransportError {
  let tcp = @socket.Tcp::connect_to_host(host, port~) catch {
    error => raise @transport.TransportError::Network(error.to_string())
  }
  Connection::wrap(tcp)
}

///|
/// 经代理拨号。SOCKS5 本轮是占位（docs/17 口径 3，握手字节属协议层，
/// 下一个提交补齐）；CONNECT 代理的语义与旧栈一致（docs/09）：
/// http 目标也走隧道，凭据只落在 CONNECT 请求上。
async fn dial_via_proxy(
  target : Target,
  endpoint : @transport.ProxyEndpoint,
) -> Connection raise @transport.TransportError {
  let proxy = parse_target(endpoint.url)
  if proxy.scheme == "socks5" {
    raise @transport.TransportError::Unsupported(
      "SOCKS5 代理即将支持（httpconn 第 1 期分两个提交落地），本次请求未发出",
    )
  }
  let conn = connect_tcp(proxy.host, proxy.port)
  errdefer conn.close()
  // CONNECT 之后按目标是否 https 决定要不要叠 TLS；隧道本身总是明文建立的
  let upgraded = establish_tunnel(conn, target, endpoint.authorization)
  if target.use_tls {
    upgraded.upgrade_tls(target.host) catch {
      error => raise @transport.TransportError::Network(error.to_string())
    }
  } else {
    upgraded
  }
}

///|
/// 发 `CONNECT host:port` 并等到 2xx；此后这条连接就是到目标的裸管道。
/// 非 2xx 翻译成人话（与旧栈的 ProxyError 映射同一条文案口径）：
/// `407` 需要认证最常见，把状态码带出来比一句「网络失败」有用。
async fn establish_tunnel(
  conn : Connection,
  target : Target,
  authorization : String?,
) -> Connection raise @transport.TransportError {
  let authority = "\{target.host}:\{target.port}"
  let headers = @httpproto.HeaderMap::new()
  headers.append("Host", authority)
  match authorization {
    Some(value) => headers.append("Proxy-Authorization", value)
    None => ()
  }
  let head = @httpproto.render_request_head("CONNECT", authority, headers) catch {
    // 渲染失败是「请求构造不出来」，属发不出去一类
    _ =>
      raise @transport.TransportError::Unsupported("CONNECT 请求构造失败")
  }
  conn.write(head) catch {
    error => raise @transport.TransportError::Network(error.to_string())
  }
  let status_line = match conn.read_line() {
    Some(line) => line
    None =>
      raise @transport.TransportError::Network(
        "代理关闭了连接，CONNECT 响应缺失",
      )
  }
  let status = @httpproto.parse_status_line(status_line) catch {
    _ =>
      raise @transport.TransportError::Network(
        "代理响应不是 HTTP 状态行",
      )
  }
  if status.code < 200 || status.code >= 300 {
    raise @transport.TransportError::Network(
      "代理拒绝建立隧道：HTTP \{status.code} \{status.reason}",
    )
  }
  // 读掉 CONNECT 响应的头块，让管道停在「干净的响应边界」上
  discard_head_block(conn)
  conn
}

///|
/// 逐行读掉一个头块（直到空行）。隧道握手与 1xx 跳过共用。
async fn discard_head_block(
  conn : Connection,
) -> Unit raise @transport.TransportError {
  while true {
    let line = conn.read_line()
    if line is Some("") {
      return
    }
    if line is None {
      raise @transport.TransportError::Network("连接在头块中途关闭")
    }
  }
}

///|
/// 从连接上读一行（到 CRLF 为止，分隔符被消费）。行读取都走它：
/// 默认 trait 方法的错误类型是宽的 `Error`，在这里收敛成 `TransportError`，
/// 调用方（隧道握手 / 响应头）才不用各自兜一圈。
async fn Connection::read_line(
  self : Connection,
) -> String? raise @transport.TransportError {
  self.read_until("\r\n") catch {
    error => raise @transport.TransportError::Network(error.to_string())
  }
}
