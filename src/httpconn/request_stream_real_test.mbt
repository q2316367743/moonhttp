// 流式上传（docs/20）的真连接用例：裸 TCP server 读下客户端发出的请求体，
// 验证「泵循环 + 双模式分帧」的线上行为：
// - 无声明长度 → Transfer-Encoding: chunked（分帧头由栈接管、多块、终止帧）；
// - 声明长度 → Content-Length 定长（字节原样到达、进度 total 已知）；
// - 声明与实际不符 → Malformed（本地数据与声明对不上，不是对端的错）；
// - 读源中途失败 → Network（与写失败同一映射）。

///|
/// 测试数据量：超过一个 UPLOAD_CHUNK_SIZE（64 KiB），逼出「多块泵送」。
const STREAM_UPLOAD_SIZE : Int = 200000

///|
/// 起一个把请求头逐行收进数组的裸 TCP server，读到空行后交给回调。
/// 回调里抛错会被吞掉——用例 3/4 的客户端会主动断开，服务端读体
/// 必须容许 EOF，不能让 server 任务失败污染 task group。
async fn uploading_server(
  group : @async.TaskGroup[Unit],
  handle : async (@socket.Tcp, Array[String]) -> Unit,
) -> Int {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((tcp, _addr) => {
      try {
        let lines : Array[String] = []
        let mut head_end = false
        while !head_end {
          match tcp.read_until("\n") {
            None => break
            Some(line) =>
              if line == "\r" || line == "" {
                head_end = true
              } else {
                lines.push(line)
              }
          }
        }
        handle(tcp, lines)
      } catch {
        _ => ()
      }
    })
  }
  port
}

///|
/// 把请求头各行拼成一段文本供 contains 断言用。
/// 数组的 to_string 走 Show 已废弃，这里显式拼接，不依赖调试渲染格式。
fn join_header_lines(lines : Array[String]) -> String {
  let sb = StringBuilder()
  for line in lines {
    sb.write_string(line)
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// 十六进制解析 chunk-size 行（测试数据是纯 'x'，不含换行，
/// 行法解析 chunked 在这里是安全的）。
fn parse_hex_size(text : StringView) -> Int? {
  let mut value = 0
  let mut any = false
  for c in text {
    let digit = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      return None
    }
    value = value * 16 + digit
    any = true
  }
  if any {
    Some(value)
  } else {
    None
  }
}

///|
/// 按行法读完一个 chunked 请求体：返回 (总字节数, chunk 个数)。
/// 每个数据块与它的 CRLF 同在一条「行」里（数据无换行），长度正好 size + 2。
async fn read_chunked_upload(tcp : @socket.Tcp) -> (Int, Int) {
  let mut total = 0
  let mut chunks = 0
  while true {
    let size = match tcp.read_until("\n") {
      Some(line) =>
        match parse_hex_size(line.trim()) {
          Some(size) => size
          None => fail("坏 chunk-size 行：\{line}")
        }
      None => fail("chunk-size 行之前连接断了")
    }
    if size == 0 {
      // 终止帧的 0 行已读，再吃掉 trailer 的空行（render_last_chunk 的收尾）
      ignore(tcp.read_until("\n"))
      break
    }
    // 数据块不走行法：单个 chunk 64 KiB，read_until 的行缓冲在超长行上会丢字节
    //（实测 UInt16 界），用 read_exactly 按 size + 2 精确收（数据 + CRLF）。
    let piece = tcp.read_exactly(size + 2)
    if piece[piece.length() - 2] != b'\r' || piece[piece.length() - 1] != b'\n' {
      fail("chunk 数据没有以 CRLF 结尾")
    }
    total += size
    chunks += 1
  }
  (total, chunks)
}

///|
/// 发一份流式请求体到指定端口。
async fn send_stream(
  port : Int,
  stream : @transport.StreamBody,
  on_progress? : @transport.ProgressCallback,
) -> @transport.RawResponse raise @transport.TransportError {
  let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()
  transport.send({
    http_method: @transport.Method::Post,
    url: "http://127.0.0.1:\{port}/upload",
    headers: @transport.Headers::new(),
    body: Some(@transport.RequestBody::Stream(stream)),
    timeout: Some(5000),
    proxy: None,
    on_upload_progress: on_progress,
    signal: None,
  })
}

///|
/// 无声明长度：分帧头由栈接管（chunked、没有 Content-Length），
/// 多块泵送、终止帧齐、总字节一字不差；进度 total 为 None。
async test "real connection pumps a chunked stream upload" {
  let data = Bytes::make(STREAM_UPLOAD_SIZE, b'x')
  let reader : &@io.Reader = @io.MemoryReader() <| writer => {
    writer.write(data)
  }
  let seen : Array[(Int, Int?)] = []
  @async.with_task_group() <| group => {
    let port = uploading_server(group, (tcp, lines) => {
      let header_text = join_header_lines(lines)
      // 分帧头由栈全权接管：chunked 在、Content-Length 不在
      assert_true(header_text.contains("Transfer-Encoding: chunked"))
      assert_false(header_text.contains("Content-Length"))
      let (total, chunks) = read_chunked_upload(tcp)
      // 超过一个 UPLOAD_CHUNK_SIZE 必须拆成多块
      assert_eq(total, STREAM_UPLOAD_SIZE)
      assert_true(chunks >= 2)
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n200000")
    })
    let raw = send_stream(port, { reader, content_length: None, }, on_progress=fn(
      event,
    ) {
      seen.push((event.loaded, event.total))
    })
    assert_eq(raw.body.read_all(), b"200000")
  }
  // chunked 模式 total 未知；最后一块报告全部字节
  assert_true(seen.length() >= 2)
  assert_true(seen[seen.length() - 1] is (STREAM_UPLOAD_SIZE, None))
}

///|
/// 声明长度：Content-Length 定长、无 Transfer-Encoding，字节原样到达；
/// 进度 total 已知，末次 loaded 等于声明值。
async test "real connection pumps a fixed-length stream upload" {
  let data = Bytes::make(STREAM_UPLOAD_SIZE, b'x')
  let reader : &@io.Reader = @io.MemoryReader() <| writer => {
    writer.write(data)
  }
  let seen : Array[(Int, Int?)] = []
  @async.with_task_group() <| group => {
    let port = uploading_server(group, (tcp, lines) => {
      let header_text = join_header_lines(lines)
      assert_true(header_text.contains("Content-Length: 200000"))
      assert_false(header_text.contains("Transfer-Encoding"))
      let received = tcp.read_exactly(STREAM_UPLOAD_SIZE)
      assert_eq(received.length(), STREAM_UPLOAD_SIZE)
      assert_eq(received[0], b'x')
      assert_eq(received[received.length() - 1], b'x')
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok!")
    })
    let raw = send_stream(
      port,
      { reader, content_length: Some(STREAM_UPLOAD_SIZE), },
      on_progress=fn(event) { seen.push((event.loaded, event.total)) },
    )
    assert_eq(raw.body.read_all(), b"ok!")
  }
  assert_true(seen.length() >= 2)
  assert_true(
    seen[seen.length() - 1] is (STREAM_UPLOAD_SIZE, Some(STREAM_UPLOAD_SIZE)),
  )
}

///|
/// 声明 100 字节、实际只有 5 字节：泵送在 EOF 后校验不符，报 Malformed
/// ——本地数据与声明对不上，不是对端的问题。
async test "declared length mismatch fails as Malformed" {
  let reader : &@io.Reader = @io.MemoryReader() <| writer => {
    writer.write(b"short")
  }
  @async.with_task_group() <| group => {
    // 服务端只读头：客户端会在写完 5 字节后主动断开（errdefer 关连接）
    let port = uploading_server(group, (tcp, _lines) => {
      ignore(tcp.read_exactly(100))
    })
    let error = try {
      ignore(send_stream(port, { reader, content_length: Some(100), }))
      None
    } catch {
      @transport.TransportError::Malformed(_) => Some("malformed")
      _ => Some("other")
    }
    assert_eq(error, Some("malformed"))
  }
}

///|
/// 读源中途失败（MemoryReader 回调抛错）：归 Network，与写失败同一映射。
async test "failing stream source surfaces as Network" {
  let reader : &@io.Reader = @io.MemoryReader() <| writer => {
    writer.write(b"partial-data")
    raise Failure::Failure("source exploded")
  }
  @async.with_task_group() <| group => {
    let port = uploading_server(group, (tcp, _lines) => {
      ignore(read_chunked_upload(tcp))
    })
    let error = try {
      ignore(send_stream(port, { reader, content_length: None, }))
      None
    } catch {
      @transport.TransportError::Network(_) => Some("network")
      _ => Some("other")
    }
    assert_eq(error, Some("network"))
  }
}
