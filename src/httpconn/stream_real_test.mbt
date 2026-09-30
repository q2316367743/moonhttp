// httpconn 的真连接用例：裸 TCP server（不依赖任何 HTTP 库）+ 完整的
// Transport::send 链路。真实缺陷都长在「真连接的读路径」上（分帧、
// 头后残留、边到边读），这些用例把它们钉死：
// - 分帧响应体的边到边读取（server 停顿期间第一段必须已经能读到）；
// - 响应头与正文同段到达时，「头后残留」必须过一遍分帧而不是原样漏出；
// - 自定义方法的请求行原样落线（docs/16 的解锁目标，端到端证据）。

///|
/// 起一个裸 TCP server：读到请求头结束（空行）后把连接交给回调。
async fn raw_server(
  group : @async.TaskGroup[Unit],
  handle : async (@socket.Tcp) -> Unit,
) -> Int {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((tcp, _addr) => {
      // 读掉请求头：请求行 + 头块，到空行为止（本文件的用例都不发请求体）
      let mut head_end = false
      while !head_end {
        match tcp.read_until("\n") {
          None => break
          Some(line) => if line == "\r" || line == "" { head_end = true }
        }
      }
      handle(tcp)
    })
  }
  port
}

///|
async fn send_simple(
  meth : String,
  port : Int,
  path : String,
) -> @transport.RawResponse {
  let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()
  transport.send({
    http_method: @transport.Method::Other(meth),
    url: "http://127.0.0.1:\{port}\{path}",
    headers: @transport.Headers::new(),
    body: None,
    timeout: Some(5000),
    proxy: None,
    on_upload_progress: None,
    signal: None,
  })
}

///|
/// chunked 分帧响应体的边到边读取：server 发完头与第一段就停顿，
/// 客户端必须能在这段停顿里读到第一段——「传输层退回一次性读满」会让
/// `sent_tail` 标志位先被置位，断言随即失败。
async test "real connection streams a chunked body edge-to-edge" {
  let sent_tail : Array[Bool] = [false]
  @async.with_task_group() <| group => {
    let port = raw_server(group, tcp => {
      tcp.write(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
      tcp.write(b"d\r\ndata: first\n\n\r\n")
      // 停顿足够长，避免「客户端读得慢」被误判成「传输层没流式读」
      @async.sleep(800)
      sent_tail[0] = true
      tcp.write(b"e\r\ndata: second\n\n\r\n0\r\n\r\n")
    })
    let raw = send_simple("GET", port, "/events")
    assert_eq(raw.status, 200)
    assert_eq(raw.body.read_until("\n\n"), Some("data: first"))
    assert_true(!sent_tail[0])
    assert_eq(raw.body.read_until("\n\n"), Some("data: second"))
    assert_eq(raw.body.read_until("\n\n"), None)
  }
}

///|
/// 回归用例（2026-09-30）：响应头与正文**同段到达**时，读头的「多读」会把
/// 正文（连 chunked 帧头一起）留在连接缓冲里；BodyReader 曾与连接共用这份
/// 缓冲，而默认读方法「缓冲有字节就直接交出、不再过 _direct_read」，
/// 于是帧原样漏进了响应体（读到的是 "d\r\ndata: …" 这种线上字节）。
/// 修复后 BodyReader 自持输出缓冲，残留字节一律作为线上输入过一遍分帧。
async test "bytes left behind the response head still go through framing" {
  @async.with_task_group() <| group => {
    let port = raw_server(group, tcp => {
      // 头、chunked 帧与正文一次性写完（一个 TCP 段），制造最大残留
      tcp.write(
        b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
      )
      // 保持连接打开：分帧完成不该依赖连接关闭
      @async.sleep(10000)
    })
    let raw = send_simple("GET", port, "/one-segment")
    assert_eq(raw.status, 200)
    // 终止 chunk 之后就该 EOF：连接还开着也不能等出下一份响应
    assert_eq(raw.body.read_all(), b"hello world")
  }
}

///|
/// 定长分帧同样要吃掉「头后残留」：`Content-Length` 的响应体不允许把
/// 帧外字节带进来，读到定长即止（哪怕连接还开着）。
async test "content-length framing consumes exactly the declared bytes" {
  @async.with_task_group() <| group => {
    let port = raw_server(group, tcp => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world")
      @async.sleep(10000)
    })
    let raw = send_simple("GET", port, "/length")
    assert_eq(raw.body.read_all(), b"hello world")
  }
}

///|
/// 自定义方法端到端：`PROPFIND` 的请求行**原样**落线（token 大小写由调用方
/// 保证，见 `Method::to_string` 的口径），server 回显请求行，客户端核对。
/// 旧栈受底层封闭枚举所限发不出这个方法（docs/16），这是切换自研栈的目标之一。
///
/// 这条自带 server（不预先读干请求头）：回显要的正是第一行。
async test "custom method reaches the wire verbatim" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer::TcpServer(
      @socket.Addr::parse("127.0.0.1:0"),
    )
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((tcp, _addr) => {
        // 只读请求行，原样核对后按定长体回显（请求行 23 字节，回显体 28 字节）
        let request_line = match tcp.read_until("\r\n") {
          Some(line) => line
          None => "<EOF>"
        }
        if request_line != "PROPFIND /cal/ HTTP/1.1" {
          // 服务端先核对：请求行不是原样落线就直接暴露（定长体会对不上）
          tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nMISMATCH")
        } else {
          tcp.write(
            b"HTTP/1.1 200 OK\r\nContent-Length: 28\r\n\r\nline=PROPFIND /cal/ HTTP/1.1",
          )
        }
      })
    }
    let raw = send_simple("PROPFIND", port, "/cal/")
    assert_eq(raw.status, 200)
    assert_eq(raw.body.read_all(), b"line=PROPFIND /cal/ HTTP/1.1")
  }
}

///|
/// 非法 token 的自定义方法在**建连之前**被拦（httpconn_test.mbt 已有拒连
/// 地址的版本；这里换成真 server：端口在监听，但 server 侧一次连接都不该收到
/// ——拦截发生在拨号之前，计数器保持为 0 才算数）。
async test "invalid method token never reaches a listening server" {
  let accepted : Array[Bool] = [false]
  @async.with_task_group() <| group => {
    let port = raw_server(group, _tcp => accepted[0] = true)
    let error = try {
      ignore(send_simple("BAD METHOD", port, "/x"))
      None
    } catch {
      error => Some(error)
    }
    assert_true(error is Some(@transport.TransportError::Unsupported(_)))
    assert_true(!accepted[0])
  }
}
