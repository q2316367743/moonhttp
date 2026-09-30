// 自研 HTTP/1.x 传输实现：`Transport` trait 的真实实现，
// 2026-09-30 起是 `Client::new` 的缺省 transport（旧栈 AsyncHttpTransport 已删除，
// 对照见 docs/18）。它带来的能力：
// - **自定义方法**：请求行由 httpproto 渲染，方法 token 原样落线
//   （`PROPFIND` 等 WebDAV 方法开箱即用，docs/16）；
// - **gzip 自持**：声明与解压都在本实现内完成（docs/17 口径 4）；
// - 连接生命周期可见（阶段 2 的连接池在这里打地基）。

///|
/// 自研 HTTP/1.x 传输实现。无状态：phase 1 每请求一条连接，
/// 连接池是阶段 2 的事（docs/17 分期表）。
pub struct HttpConnTransport {}

///|
/// 创建自研传输实现。
pub fn HttpConnTransport::new() -> HttpConnTransport {
  HttpConnTransport::{ }
}

///|
/// 发送一次请求：建连（含代理握手）→ 写头写体 → 等响应头，
/// 然后把「还开着的连接」按分帧交给响应体流。
///
/// 取消作用域包住**整跳**（Transport 契约的一半）：建连、TLS 握手、
/// CONNECT 握手、写头、写体（含上传进度回调）、等响应头。从上传进度
/// 回调里取消也落在同一个子任务上，下一块写出去之前就会断。
/// 响应体阶段的超时与取消由 `ResponseBody` 按**单次读取**管。
pub impl @transport.Transport for HttpConnTransport with fn send(self, request) {
  ignore(self)
  @transport.with_abort_scope(request.signal, () => send_head(request))
}

///|
/// 建连到响应头的整段（含等响应头）受 `timeout` 约束，错误统一收敛为
/// `@transport.TransportError`：超时、协议解析（Malformed / Unsupported 原样对应）、
/// 其余（DNS、拒连、TLS、代理拒绝……）归网络层并保留原始文本。
async fn send_head(
  request : @transport.PreparedRequest,
) -> @transport.RawResponse raise @transport.TransportError {
  // 方法 token 校验在**建连前**（docs/16 落地清单的要求）：
  // 拼不进请求行的方法不值得一次 TCP/TLS 握手
  let meth = request.http_method.to_string()
  if !@httpproto.is_token(meth) {
    raise @transport.TransportError::Unsupported(
      "请求方法不是合法 token：\{meth}",
    )
  }
  let target = parse_target(request.url)
  if target.scheme == "socks5" {
    // socks5 只为「代理地址的解析」而认识；作为请求目标没有 HTTP 语义
    raise @transport.TransportError::Unsupported(
      "请求目标只支持 http/https 协议：\{target.scheme}",
    )
  }
  let attempt = () => {
    let conn = dial(target, request.proxy)
    errdefer conn.close()
    let headers = build_request_headers(request, target)
    write_request_head(conn, meth, target.target, headers)
    match request.body {
      Some(bytes) => write_request_body(conn, bytes, request.on_upload_progress)
      None => ()
    }
    let head = read_response_head(conn)
    build_raw_response(conn, request, meth, head)
  }
  try {
    // timeout 为 None 或非正数时不加限制
    match request.timeout {
      Some(milliseconds) if milliseconds > 0 =>
        @async.with_timeout(milliseconds, attempt)
      _ => attempt()
    }
  } catch {
    @async.TimeoutError => raise @transport.TransportError::Timeout
    // 解析错误的两类原样对应：语法坏 → Malformed（ERR_BAD_RESPONSE），
    // 能力边界（HTTP/2 前言等）→ Unsupported（ERR_NOT_SUPPORTED）
    @httpproto.ParseError::Malformed(message) =>
      raise @transport.TransportError::Malformed(message)
    @httpproto.ParseError::Unsupported(message) =>
      raise @transport.TransportError::Unsupported(message)
    // 自己人（dial / 读写辅助函数）抛的 TransportError 原样透传：
    // 里面是翻好的文案（隧道 407 的「代理拒绝建立隧道：HTTP 407 …」等），
    // 落到下面的 catch-all 会被包成「Network(TransportError.Network)」，
    // 把人话冲成一句类型名。
    @transport.TransportError::Network(message) =>
      raise @transport.TransportError::Network(message)
    @transport.TransportError::Malformed(message) =>
      raise @transport.TransportError::Malformed(message)
    @transport.TransportError::Unsupported(message) =>
      raise @transport.TransportError::Unsupported(message)
    @transport.TransportError::Cancelled(reason) =>
      raise @transport.TransportError::Cancelled(reason)
    @transport.TransportError::Timeout =>
      raise @transport.TransportError::Timeout
    // 其余（建连、TLS……）归网络层，保留原始文本
    error => raise @transport.TransportError::Network(error.to_string())
  }
}

///|
/// 响应头到手后的收尾：multimap 压平（取最后一个值）、按需解 gzip、
/// 组装带连接所有权的 `RawResponse`。
///
/// 压平规则（docs/17 待决问题的落地）：同名头取最后一个值；
/// `Set-Cookie` 的多值全量收集进 `set_cookies`（docs/05 / 17 挂起的
/// 「响应 cookie」落在这里，cookie jar 的自动维护吃的是这份列表）。
///
/// gzip（谁解压谁声明，docs/15）：只有「请求没声明 Accept-Encoding、
/// 由我们声明了 gzip」这条路径才解压——用户自己声明的交给上层
/// （缓冲路径 `decode_response_body` / 流式按自描述原则交原字节），
/// `identity` 声明（decompress: false）更是一概不动。解压后
/// `Content-Encoding` 与 `Content-Length` 都成了假话，一并摘掉
/// （`total` 随之归 `None`）。
fn build_raw_response(
  conn : Connection,
  request : @transport.PreparedRequest,
  meth : String,
  head : ResponseHead,
) -> @transport.RawResponse raise @transport.TransportError {
  let mut headers = @headers.Headers::new()
  let set_cookies : Array[String] = []
  for entry in head.headers.entries {
    let (name, value) = entry
    if name.to_lower() == "set-cookie" {
      set_cookies.push(value)
    }
    headers = headers.set(name, value)
  }
  let framing = @httpproto.body_framing(meth == "HEAD", head.code, head.headers) catch {
    @httpproto.ParseError::Malformed(message) =>
      raise @transport.TransportError::Malformed(message)
    @httpproto.ParseError::Unsupported(message) =>
      raise @transport.TransportError::Unsupported(message)
  }
  let total = match framing {
    @httpproto.BodyFraming::Length(value) => Some(value)
    _ => None
  }
  let mut reader : &@io.Reader = BodyReader::open(conn, framing)
  let declared_by_us = !request.headers.has("Accept-Encoding")
  let response_is_gzip = match headers.get("Content-Encoding") {
    Some(value) => value.trim(chars=" \t").to_lower() == "gzip"
    None => false
  }
  if declared_by_us && response_is_gzip {
    reader = @gzip.Decoder(reader)
    headers = headers.remove("Content-Encoding").remove("Content-Length")
  }
  @transport.RawResponse::{
    status: head.code,
    status_text: head.reason,
    headers,
    set_cookies,
    // 连接的所有权在这里移交：读到 EOF 或 close() 时释放
    //（errdefer 只覆盖到这一行为止的失败路径）。
    body: @transport.ResponseBody::open_wire(
      reader,
      fn() { conn.close() },
      timeout=request.timeout,
      total~,
      signal=request.signal,
    ),
  }
}

///|
pub extend HttpConnTransport with @transport.Transport::{send}
