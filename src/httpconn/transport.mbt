// 自研 HTTP/1.x 传输实现：`Transport` trait 的真实实现，
// 2026-09-30 起是 `Client::new` 的缺省 transport（旧栈 AsyncHttpTransport 已删除，
// 对照见 docs/18）。它带来的能力：
// - **自定义方法**：请求行由 httpproto 渲染，方法 token 原样落线
//   （`PROPFIND` 等 WebDAV 方法开箱即用，docs/16）；
// - **gzip 自持**：声明与解压都在本实现内完成（docs/17 口径 4）；
// - **连接池**：空闲连接按「服务谁」分桶复用，省掉重复握手
//   （2026-10 落地，契约见 docs/17 口径 4，设计与实现见 docs/21）。

///|
/// 自研 HTTP/1.x 传输实现。状态只有池：同一个实例派生的所有
/// `Client`（`Client::create` 共享 transport 引用）共享同一池。
pub struct HttpConnTransport {
  priv pool : ConnectionPool
}

///|
/// 创建自研传输实现。
///
/// - `max_idle_per_host`：每 host 的空闲连接上限，缺省 4；
///   传 0 禁用池（行为退回 phase 1：每请求一条连接 + `Connection: close`）。
/// - `idle_timeout_ms`：空闲连接的保活时长，缺省 30 秒；
///   传非正数表示不过期（对端关闭由取用时的重试兜底）。
pub fn HttpConnTransport::new(
  max_idle_per_host? : Int32,
  idle_timeout_ms? : Int32,
) -> HttpConnTransport {
  let max_idle = match max_idle_per_host {
    Some(value) => value
    None => DEFAULT_MAX_IDLE_PER_HOST
  }
  let idle_timeout = match idle_timeout_ms {
    Some(value) => value
    None => DEFAULT_IDLE_TIMEOUT_MS
  }
  { pool: ConnectionPool::new(max_idle, idle_timeout), }
}

///|
/// 发送一次请求：先借池（可能免去握手）→ 写头写体 → 等响应头，
/// 然后把「还开着的连接」按分帧交给响应体流；响应体消费完由
/// dispose 回调决定还池还是关闭（docs/21）。
///
/// 取消作用域包住**整跳**（Transport 契约的一半）：建连、TLS 握手、
/// CONNECT 握手、写头、写体（含上传进度回调）、等响应头。从上传进度
/// 回调里取消也落在同一个子任务上，下一块写出去之前就会断。
/// 响应体阶段的超时与取消由 `ResponseBody` 按**单次读取**管。
pub impl @transport.Transport for HttpConnTransport with fn send(self, request) {
  @transport.with_abort_scope(request.signal, () => self.send_head(request))
}

///|
/// 建连到响应头的整段（含等响应头）受 `timeout` 约束，错误统一收敛为
/// `@transport.TransportError`：超时、协议解析（Malformed / Unsupported 原样对应）、
/// 其余（DNS、拒连、TLS、代理拒绝……）归网络层并保留原始文本。
///
/// 重试口径（docs/17 分期表「取用时坏连接重试一次」）：借来的连接可能
/// 早已被对端悄悄关掉，**响应开始之前**的失败（写失败 / 状态行干净 EOF，
/// 即 `StaleConnection`）在请求体可回卷（无体或缓冲体）时换新连接重试
/// 一次。重试与首跳共享同一个 timeout 预算。
async fn HttpConnTransport::send_head(
  self : HttpConnTransport,
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
  let key = pool_key(target, request.proxy)
  let reused = self.pool.acquire(key)
  // 池禁用时保留 phase 1 的线上行为：声明 close 让服务端立刻回收
  let declare_close = self.pool.disabled()
  // 重试资格的一半：请求体可回卷（无体或缓冲体）。流式体读过的字节
  // 拿不回来，重试等于换一份内容，直接报错。
  let replayable = request.body is (None | Some(Buffered(_)))
  let run = (conn : Connection) => {
    // errdefer 只覆盖到 build_raw_response 为止的失败路径：
    // 失败（含取消）一律毒化关闭；成功则连接所有权随响应体移交，
    // 结局由 dispose 回调定（读完还池 / 半途关闭）。
    errdefer conn.close()
    let headers = build_request_headers(request, target, declare_close)
    write_request_head(conn, meth, target.target, headers)
    match request.body {
      Some(body) => write_request_body(conn, body, request.on_upload_progress)
      None => ()
    }
    let head = read_response_head(conn)
    self.build_raw_response(key, conn, request, meth, head)
  }
  let send_once = () => {
    match reused {
      Some(conn) =>
        if replayable {
          run(conn) catch {
            StaleConnection(_) => {
              // 死连接已被 errdefer 关掉。此时请求还没被服务端开始响应
              //（最多是「发出去了但没等到头」），换新连接再试一次。
              // 缓冲体与上传进度回调会因此重放一遍，见 docs/21。
              let fresh = dial(target, request.proxy)
              run(fresh)
            }
            // 其余失败不是「借来的连接死了」，原样外抛
            error => raise error
          }
        } else {
          run(conn)
        }
      None => {
        let fresh = dial(target, request.proxy)
        run(fresh)
      }
    }
  }
  try {
    // timeout 为 None 或非正数时不加限制
    match request.timeout {
      Some(milliseconds) if milliseconds > 0 =>
        @async.with_timeout(milliseconds, send_once)
      _ => send_once()
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
    // 坏连接信号到了这里 = 没资格重试（新连接死了，或流式体不可回卷）：
    // 对端在响应开始前断开是网络失败（不再是 phase 1 的 Malformed）
    StaleConnection(message) =>
      raise @transport.TransportError::Network(message)
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
///
/// 复用判定（docs/21）在响应头层面先定「服务端允许不允许」：
/// 分帧不是 UntilClose（体以关闭收尾，天然不可复用）、请求方没自己
/// 声明 close、`connection_reusable`（版本 × Connection 头规则）通过。
/// 「体读没读满」由 BodyReader 的读取状态补全，两者在 dispose 时合取。
fn HttpConnTransport::build_raw_response(
  self : HttpConnTransport,
  key : String,
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
  let request_declared_close = match request.headers.get("Connection") {
    Some(value) => @httpproto.declares_close(value)
    None => false
  }
  let server_allows = !(framing is @httpproto.BodyFraming::UntilClose) &&
    !request_declared_close &&
    @httpproto.connection_reusable(head.version, head.headers)
  let body_reader = BodyReader::open(conn, framing, server_allows~)
  let mut reader : &@io.Reader = body_reader
  let declared_by_us = !request.headers.has("Accept-Encoding")
  let response_is_gzip = match headers.get("Content-Encoding") {
    Some(value) => value.trim(chars=" \t").to_lower() == "gzip"
    None => false
  }
  if declared_by_us && response_is_gzip {
    reader = @gzip.Decoder(reader)
    headers = headers.remove("Content-Encoding").remove("Content-Length")
  }
  let pool = self.pool
  @transport.RawResponse::{
    status: head.code,
    status_text: head.reason,
    headers,
    set_cookies,
    // 连接的所有权在这里移交：EOF / close() 之外的失败由 errdefer 兜底，
    // EOF 与显式释放走 dispose——读完且可复用则还池，否则关闭（docs/21）。
    body: @transport.ResponseBody::open_wire_dispose(
      reader,
      fn(end) {
        match end {
          Finished =>
            if body_reader.is_reusable() {
              pool.release(key, conn)
            } else {
              conn.close()
            }
          // 半途放弃 / 读失败 / 取消：字节流停在哪不可知，一律毒化
          Abandoned => conn.close()
        }
      },
      timeout=request.timeout,
      total~,
      signal=request.signal,
    ),
  }
}

///|
pub extend HttpConnTransport with @transport.Transport::{send}
