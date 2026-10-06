// chunked 发送侧渲染的规则测试。除了形状断言，还有一组与解码状态机的
// 往返测试：渲染 → 喂给 ChunkDecoder → 解出的数据应与原始输入一致——
// 发送与接收两侧的规则因此互相钉死，任何一侧单独改动都会被抓住。

///|
test "render_chunk_frame：小数据的完整形状" {
  assert_eq(@httpproto.render_chunk_frame(b"hello"), b"5\r\nhello\r\n")
}

///|
test "render_chunk_frame：一位十六进制只占一个字符" {
  assert_eq(@httpproto.render_chunk_frame(b"a"), b"1\r\na\r\n")
}

///|
test "render_chunk_frame：长度超过一位十六进制时逐位展开（小写）" {
  // 65536 = 0x10000：长度行必须是 5 个字符的小写 hex，没有前导零
  let frame = @httpproto.render_chunk_frame(Bytes::make(65536, b'x'))
  // 7 字节前缀（5 位 hex + CRLF）+ 65536 数据 + 2 字节 CRLF
  assert_eq(frame.length(), 65536 + 9)
  assert_eq(frame.exact_view(start=0, end=7).to_owned(), b"10000\r\n")
  assert_eq(frame[frame.length() - 2], b'\r')
  assert_eq(frame[frame.length() - 1], b'\n')
}

///|
test "render_chunk_frame：空字节被拒绝（零长度帧等于终止帧）" {
  let rejected = try {
    ignore(@httpproto.render_chunk_frame(b""))
    false
  } catch {
    @httpproto.ParseError::Malformed(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
test "render_last_chunk：固定形状 0 CRLF CRLF" {
  assert_eq(@httpproto.render_last_chunk(), b"0\r\n\r\n")
}

///|
/// 渲染 → 解码的往返：任意大小的数据按任意切法渲染成多帧，解码结果
/// 应拼回原始输入，且 `finish()` 正常收尾（终止帧在、报文完整）。
fn roundtrip(data : Bytes, frame_size : Int) -> Unit raise {
  let wire = @buffer.Buffer::Buffer()
  let mut start = 0
  while start < data.length() {
    let end = if start + frame_size < data.length() {
      start + frame_size
    } else {
      data.length()
    }
    wire.write_bytes(
      @httpproto.render_chunk_frame(data.exact_view(start~, end~).to_owned()),
    )
    start = end
  }
  // 空输入也要有终止帧：chunked 报文的最小形状就是「只有终止帧」
  wire.write_bytes(@httpproto.render_last_chunk())
  let decoder = @httpproto.ChunkDecoder::new()
  let out = @buffer.Buffer::Buffer()
  for piece in decoder.feed(wire.to_bytes()) {
    out.write_bytes(piece)
  }
  decoder.finish()
  assert_eq(out.to_bytes(), data)
}

///|
test "渲染与解码往返：多组大小与切法" {
  roundtrip(b"moonbit", 3)
  roundtrip(Bytes::make(1, b'a'), 100)
  roundtrip(Bytes::make(70000, b'z'), 65536)
  roundtrip(Bytes::make(0, b'x'), 4096)
}
