// chunked 增量解码的规则测试。核心是「任意切点都正确」：
// 每个正例都额外跑一遍逐字节喂入，钉死 CRLF / 行 / 数据跨 feed 的边界。

///|
/// 把一份字节按 n 个字节一段切开依次喂入，收集全部解出的数据段。
fn decode_in_pieces(input : Bytes, piece_size : Int) -> Array[Bytes] raise {
  let decoder = @httpproto.ChunkDecoder::new()
  let out : Array[Bytes] = []
  let mut i = 0
  while i < input.length() {
    let stop = if i + piece_size > input.length() {
      input.length()
    } else {
      i + piece_size
    }
    for piece in decoder.feed(input.exact_view(start=i, end=stop).to_owned()) {
      out.push(piece)
    }
    i = stop
  }
  decoder.finish()
  out
}

///|
/// 拼接解出的数据段，方便整段断言。
fn joined(pieces : Array[Bytes]) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  for piece in pieces {
    buf.write_bytes(piece)
  }
  buf.to_bytes()
}

///|
/// 双 chunk 正例：数据在任意切点下都完整解出，且不多不少。
test "two chunks decode identically at every split point" {
  let wire = b"4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
  let expected = b"Wikipedia"
  // 一次喂完
  assert_eq(joined(decode_in_pieces(wire, wire.length())), expected)
  // 逐字节喂：切点最恶劣的情形
  assert_eq(joined(decode_in_pieces(wire, 1)), expected)
  // 中间粒度
  assert_eq(joined(decode_in_pieces(wire, 3)), expected)
  assert_eq(joined(decode_in_pieces(wire, 7)), expected)
}

///|
/// chunk-size 的扩展（`;ext`）解析后忽略；多个 chunk、空 chunk 都合法。
test "chunk extensions are ignored and zero-size chunks pass" {
  let wire = b"3;foo=bar;q=\"x\"\r\nabc\r\n0;done\r\n\r\n"
  assert_eq(joined(decode_in_pieces(wire, 2)), b"abc")
  // 数据段大小为 0 的 chunk：合法，解出空
  let empty_chunk = b"0\r\n\r\n"
  assert_eq(joined(decode_in_pieces(empty_chunk, 1)), b"")
}

///|
/// trailer 节：解析后丢弃（docs/17 待决问题的口径），空行收尾；
/// 有 trailer 与没 trailer 都要走到 Done。
test "trailer section is parsed then dropped" {
  let with_trailer = b"5\r\nhello\r\n0\r\nX-Sum: 5\r\nX-Hash: deadbeef\r\n\r\n"
  let decoder = @httpproto.ChunkDecoder::new()
  ignore(decoder.feed(with_trailer))
  decoder.finish()
  assert_true(decoder.is_done())
  assert_eq(joined(decode_in_pieces(with_trailer, 4)), b"hello")
  // 立即收尾（0 后直接空行）
  let no_trailer = b"2\r\nhi\r\n0\r\n\r\n"
  assert_eq(joined(decode_in_pieces(no_trailer, 5)), b"hi")
}

///|
/// 大于喂入粒度的 chunk：Data 状态跨多次 feed 累积。
test "chunk data spanning multiple feeds is stitched" {
  let wire = b"10\r\n0123456789ABCDEF\r\n0\r\n\r\n"
  assert_eq(joined(decode_in_pieces(wire, 1)), b"0123456789ABCDEF")
  assert_eq(joined(decode_in_pieces(wire, 5)), b"0123456789ABCDEF")
  assert_eq(joined(decode_in_pieces(wire, 16)), b"0123456789ABCDEF")
}

///|
/// 坏流全部显式失败：数据后缺 CRLF、裸 LF 行尾、终止后再来字节、
/// 非十六进制尺寸、截断（finish 时没到 Done）。
test "malformed wire fails loudly" {
  // 数据后的分隔不是 CRLF
  let bad_crlf = b"4\r\nWikiXX\n5\r\npedia\r\n0\r\n\r\n"
  let decoder = @httpproto.ChunkDecoder::new()
  let error = try {
    ignore(decoder.feed(bad_crlf))
    decoder.finish()
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
  // 行尾只有 LF 没有 CR
  let bare_lf = b"4\nWiki\r\n0\r\n\r\n"
  let decoder = @httpproto.ChunkDecoder::new()
  let error = try {
    ignore(decoder.feed(bare_lf))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
  // 尺寸行不是十六进制
  let decoder = @httpproto.ChunkDecoder::new()
  let error = try {
    ignore(decoder.feed(b"xyz\r\n"))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
  // Done 之后再喂
  let decoder = @httpproto.ChunkDecoder::new()
  ignore(decoder.feed(b"0\r\n\r\n"))
  let error = try {
    ignore(decoder.feed(b"more"))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
}

///|
/// 截断：连接在终止 chunk 之前关闭，finish 必须报错——
/// 把半截数据当完整响应交出去比报错更糟。
test "truncated chunked body fails at finish" {
  let decoder = @httpproto.ChunkDecoder::new()
  ignore(decoder.feed(b"4\r\nWiki\r\n5\r\nped"))
  let error = try {
    decoder.finish()
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
  // 连 trailer 空行都差一个字节也不算完
  let decoder = @httpproto.ChunkDecoder::new()
  ignore(decoder.feed(b"0\r\n\r"))
  assert_false(decoder.is_done())
  let error = try {
    decoder.finish()
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
}
