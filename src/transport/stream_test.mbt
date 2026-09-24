// 响应体流（ResponseBody）的读语义。
//
// 前三个用例只碰内存体：它的语义刻意对齐 @io.Reader，真实连接走同一套方法
// （见 stream.mbt），所以这里锁住的是「Mock 能真实代表网络」这件事。
// 最后一个用例起一个本机 server，验证真实连接确实能边到边读。

///|
/// read_some：按 max_len 切块；读到 EOF 返回 None；close 之后继续读仍然是 None。
async test "response body reads in chunks until eof" {
  let body = @transport.ResponseBody::from_bytes(b"abcdef")
  assert_eq(body.read_some(max_len=2), Some(b"ab"))
  assert_eq(body.read_some(max_len=2), Some(b"cd"))
  // max_len 超过剩余量时只给剩下的，不会补齐也不会报错
  assert_eq(body.read_some(max_len=100), Some(b"ef"))
  assert_eq(body.read_some(max_len=2), None)
  body.close()
  assert_eq(body.read_some(max_len=2), None)
}

///|
/// read_all：一次读完剩余内容；已经读完之后再读是空的（而不是重新开始）。
async test "response body reads all remaining bytes" {
  let body = @transport.ResponseBody::from_bytes(b"hello world")
  assert_eq(body.read_all(), b"hello world")
  assert_eq(body.read_all(), b"")
}

///|
/// read_all_partial：正常读完时与 read_all 给出的字节一样，只是把「有没有失败」
/// 也交出来（这里是 `None`）。
///
/// 失败那一半（半截字节 + 错误）需要真实连接才能造出来，见根包
/// `error_test.mbt` 的两条超时用例；内存体上永远读得完，所以这里只钉住
/// 「成功路径不能因为多了个返回值就变形」。
async test "read_all_partial returns the bytes and no failure on the memory source" {
  let body = @transport.ResponseBody::from_bytes(b"hello")
  let (bytes, failure) = body.read_all_partial()
  assert_eq(bytes, b"hello")
  assert_true(failure is None)
  // 已读完（流已关闭）之后再读：空字节，依然没有失败
  let (again, failure) = body.read_all_partial()
  assert_eq(again, b"")
  assert_true(failure is None)
}

///|
/// read_until：分隔符被消费掉但不返回；末段没有分隔符时按 EOF 语义整段返回。
///
/// 用例里的中文是刻意选的：String 在 MoonBit 里是 UTF-16，按字节切只能得到
/// 合法的 UTF-8 序列，解码这一步（`@utf8.decode_lossy`）不能省。
async test "response body reads until separator" {
  let body = @transport.ResponseBody::from_bytes(
    b"data: \xe4\xb8\xad\xe6\x96\x87\n\ndata: tail",
  )
  assert_eq(body.read_until("\n\n"), Some("data: 中文"))
  assert_eq(body.read_until("\n\n"), Some("data: tail"))
  assert_eq(body.read_until("\n\n"), None)
}

///|
/// 为什么 SSE 不能用 `read_until("\n\n")` 切事件——这里把那个坑本身钉住。
///
/// CRLF 流上事件边界的字节是 `0D 0A 0D 0A`，里面**没有**连续两个 `0A`，
/// 所以按 `"\n\n"` 找分隔符是找不到的：内存体上表现为「没有分隔符 → 整段返回」，
/// 拿到的东西连边界都没切掉；在真实连接上更糟——EOF 不会来，
/// 于是会一直等到连接关闭（`timeout` 为不限时的 SSE 配置下就是永远等下去）。
///
/// 事件切分因此必须按三种行尾自己扫，见根包的 `SseParser`。
async test "read_until with two lf cannot cut crlf events" {
  let body = @transport.ResponseBody::from_bytes(b"data: x\r\n\r\n")
  // 一个分隔符都没找到，于是一整段（连边界都没切）原样返回
  assert_eq(body.read_until("\n\n"), Some("data: x\r\n\r\n"))
}

///|
/// 真实连接的流式读取：本机 server 先发响应头与第一段数据，停一下再发第二段。
///
/// 那条 `assert_true(!sent_tail[0])` 是这条用例的重点：第一段必须在这段停顿
/// 里就送到客户端。如果传输层退回「一次性读全」，第一次 read_until 只能等到
/// server 写完第二段才返回，那时标志位已经被置位，断言就会失败。
async test "async transport streams a chunked response from a real server" {
  let sent_tail : Array[Bool] = [false]
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, _body, conn) => {
        conn..send_response(200, "OK").flush()
        conn..write_string("data: first\n\n").flush()
        // 停顿留得足够长，避免「客户端读得慢」被误判成「传输层没流式读」
        @async.sleep(800)
        sent_tail[0] = true
        conn..write_string("data: second\n\n").end_response()
      })
    }
    let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
    let raw = transport.send(@transport.PreparedRequest::{
      http_method: @transport.Method::Get,
      url: "http://127.0.0.1:\{port}/events",
      headers: @transport.Headers::new().set("Accept", "text/event-stream"),
      body: None,
      // SSE 场景的典型配置：不限时。响应体读取的超时是单次读取的等待上限，
      // 这里不设限，所以停顿不会被当成超时。
      timeout: None,
      proxy: None,
      on_upload_progress: None,
      cancel_token: None,
    })
    assert_eq(raw.status, 200)
    assert_eq(raw.body.read_until("\n\n"), Some("data: first"))
    assert_true(!sent_tail[0])
    assert_eq(raw.body.read_until("\n\n"), Some("data: second"))
    assert_eq(raw.body.read_until("\n\n"), None)
  }
}

///|
/// 读取阶段的超时是「单次读取的等待上限」：server 发完第一段就挂住，
/// 客户端设了 200ms 的上限，再读就抛 `TransportError::Timeout`。
///
/// 这条用例钉住的是 `05-transport.md` 的「超时语义」：如果超时被当成
/// 整条请求的总时限，第一次读（在总时限内）之后也会立刻失败；
/// 反过来，若读取完全不设限，这里就会一直挂到 server 醒来。
async test "response body read times out after the configured wait" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, _body, conn) => {
        conn..send_response(200, "OK").flush()
        conn..write_string("data: only\n\n").flush()
        // 之后长时间不发数据，也不结束响应
        @async.sleep(3000)
        conn.end_response()
      })
    }
    let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
    let raw = transport.send(@transport.PreparedRequest::{
      http_method: @transport.Method::Get,
      url: "http://127.0.0.1:\{port}/stall",
      headers: @transport.Headers::new(),
      body: None,
      timeout: Some(200),
      proxy: None,
      on_upload_progress: None,
      cancel_token: None,
    })
    assert_eq(raw.status, 200)
    // 第一段已经在路上，能在上限内读到
    assert_eq(raw.body.read_until("\n\n"), Some("data: only"))
    // 再读就等不到数据了，按单次读取的上限报超时
    let error = try {
      ignore(raw.body.read_until("\n\n"))
      None
    } catch {
      error => Some(error)
    }
    assert_true(error is Some(@transport.TransportError::Timeout))
    // 超时后流不可再用
    assert_eq(raw.body.read_until("\n\n"), None)
  }
}
