// 进度回调的端到端用例（`on_upload_progress` / `on_download_progress`）。
//
// 两个方向各有一条走 Mock 的确定性用例（内存体的报告粒度固定，次数可精确断言），
// 以及各一条本机 server 的用例：真实连接上「块边界由对端决定」，
// 所以那两条只断言单调递增与终值，不断言次数。
//
// 配置层的用例（`progress()` 的计算、构建器、合并策略）在
// `config/progress_test.mbt`。

///|
/// 造一份指定长度的响应，body 是 `size` 个 `'x'`。
fn bytes_response(size : Int) -> @transport.RawResponse {
  {
    status: 200,
    status_text: "OK",
    headers: @transport.Headers::new().set(
      "Content-Type", "application/octet-stream",
    ),
    body: @transport.ResponseBody::from_bytes(Bytes::make(size, b'x')),
  }
}

///|
/// 造一段恰好 `size` 字节的 ASCII 文本（UTF-8 下 1 字符 = 1 字节）。
fn ascii_body(size : Int) -> String {
  let buf = StringBuilder()
  for _ in 0..<size {
    buf.write_char('x')
  }
  buf.to_string()
}

///|
/// 下载进度：`Client::request` 读全量时逐块报告，`loaded` 严格递增，
/// 最后一次等于总长度、比例为 1.0。
///
/// 内存体的报告粒度是固定的 64 KiB（见 `stream/stream_all.mbt` 的
/// `PROGRESS_CHUNK_SIZE`），所以这里能精确断言块数与每块的累计值——
/// 真实连接的块边界由对端到货节奏决定，断言不出这个。
async test "download progress reports every chunk while reading the body" {
  let size = 200 * 1024
  let mock = @transport.MockTransport::new(bytes_response(size))
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events : Array[@moonhttp.ProgressEvent] = []
  let response = client.request(
    @moonhttp.Config::new("https://example.com/big").with_on_download_progress(fn(
      event,
    ) {
      events.push(event)
    }),
  )
  assert_eq(response.bytes().length(), size)
  // 200 KiB 按 64 KiB 切：64 + 64 + 64 + 8 KiB
  assert_eq(events.length(), 4)
  assert_eq(events[0].loaded, 65536)
  assert_eq(events[1].loaded, 131072)
  assert_eq(events[2].loaded, 196608)
  assert_eq(events[3].loaded, size)
  // total 来自响应体自身的长度（内存体完整字节在手，长度总是已知）
  assert_eq(events[0].total, Some(size))
  assert_eq(events[3].total, Some(size))
  assert_eq(events[3].progress(), Some(1.0))
}

///|
/// 下载进度只挂在「库读全量」的两条路上：`StreamResponse::read_all` 报告，
/// 按块读的 `read_some` 不报告（那条路由调用方自己驱动，进度自己累加）。
///
/// 顺带钉住 `loaded` 的口径：它是**这次读全量**读到的字节数，从 0 起算，
/// 不接在之前按块读的进度后面（先读过 1 KiB 再读全量，第一次回调是 64 KiB
/// 而不是 65 KiB）。
async test "stream read all reports progress while chunked reads stay silent" {
  let size = 70 * 1024
  let mock = @transport.MockTransport::new(bytes_response(size))
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events : Array[@moonhttp.ProgressEvent] = []
  let stream = client.stream(
    @moonhttp.Config::new("https://example.com/big").with_on_download_progress(fn(
      event,
    ) {
      events.push(event)
    }),
  )
  ignore(stream.read_some(max_len=1024))
  assert_eq(events.length(), 0)
  assert_eq(stream.read_all().length(), size - 1024)
  assert_eq(events.length(), 2)
  assert_eq(events[0].loaded, 65536)
  assert_eq(events[1].loaded, size - 1024)
  // total 描述的是整个响应体，不随已读掉的部分变小
  assert_eq(events[1].total, Some(size))
}

///|
/// 上传进度：真实连接上按 64 KiB 分块写，每块之后报告一次。
///
/// 请求体是 128 KiB 的 ASCII 文本，正好切成两块——块大小是本项目的实现细节
/// （`UPLOAD_CHUNK_SIZE`），所以这里能精确断言次数与累计值。
/// 服务端必须把请求体读干净再回响应：提前收工会让客户端的写入变成
/// 「连接被重置」，那测到的就不是进度回调了。
async test "upload progress reports every chunk while writing the body" {
  let size = 128 * 1024
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, body, conn) => {
        ignore(body.read_all())
        conn..send_response(200, "OK").write_string("ok")
        conn.end_response()
      })
    }
    let client = @moonhttp.Client::new()
    let events : Array[@moonhttp.ProgressEvent] = []
    let response = client.request(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/upload")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_str(ascii_body(size))
      .with_on_upload_progress(fn(event) { events.push(event) }),
    )
    assert_eq(response.text(), "ok")
    assert_eq(events.length(), 2)
    assert_eq(events[0].loaded, 65536)
    assert_eq(events[0].total, Some(size))
    assert_eq(events[1].loaded, size)
    assert_eq(events[1].progress(), Some(1.0))
  }
}

///|
/// 响应没有 `Content-Length` 时（chunked），`total` 是 `None`、比例为 `None`：
/// 长度真的不知道，不编一个 0 出来。
///
/// 这条只能在真实连接上测：Mock 的响应体是内存字节，长度总是已知的
/// （`ResponseBody::from_bytes` 把 total 设成字节长度）。
async test "download progress has no total when the server declares no length" {
  let body_text = "chunked body"
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, _body, conn) => {
        // 不设 Content-Length：底层按 chunked 发，客户端拿不到总长度
        conn..send_response(200, "OK").write_string(body_text)
        conn.end_response()
      })
    }
    let client = @moonhttp.Client::new()
    let events : Array[@moonhttp.ProgressEvent] = []
    let response = client.request(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/data").with_on_download_progress(fn(
          event,
        ) {
          events.push(event)
        },
      ),
    )
    assert_eq(response.text(), body_text)
    // 真实连接的块边界由对端决定，只断言「至少报过一次」与终值
    assert_true(events.length() >= 1)
    let last = events[events.length() - 1]
    assert_eq(last.loaded, body_text.length())
    assert_eq(last.total, None)
    assert_eq(last.progress(), None)
  }
}
