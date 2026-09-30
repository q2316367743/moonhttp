// 响应体解码（缓冲路径）的单元用例。
//
// 白盒而不是黑盒：这里要造真的 gzip 字节（用 `@gzip` 编码器）——白盒测试
// 才看得见生产的 import 清单。

///|
/// 把字节压成 gzip 流：用 async 自带的编码器，保证产物是**真的** gzip 字节
/// （手抄一份字节串的话，抄错了用例证明的就只是「抄错的那份没人认识」）。
async fn gzip_encode(data : Bytes) -> Bytes {
  let (reader, writer) = @io.pipe()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer writer.close()
      @gzip.Encoder(writer)..write(data).end()
    }
    defer reader.close()
    reader.read_all().binary()
  }
}

///|
/// 一份声明的响应头，够 `declares_gzip` 用。
fn gzip_headers() -> @headers.Headers {
  @headers.Headers::new().set("Content-Encoding", "gzip")
}

///|
/// 往返一次：编码器产出的 gzip 字节必须能被 `decode_gzip` 原样还原。
async test "decode_gzip round trips what the async encoder produced" {
  let original = @utf8.encode(
    "gzip 往返：hello, world —— 中文与符号",
  )
  let compressed = gzip_encode(original)
  // 压缩确实发生了：否则这条用例证明不了「解压」这件事
  assert_true(compressed.length() != original.length())
  assert_eq(decode_gzip(compressed), original)
}

///|
/// 二进制内容同样要原样还原（响应体不一定是文本）。
async test "decode_gzip round trips binary content" {
  let original = Bytes::makei(4096, i => (i % 256).to_byte())
  assert_eq(decode_gzip(gzip_encode(original)), original)
}

///|
/// 空输入也有确定结论：不是合法的 gzip 流，报 `Malformed` 而不是当成空体。
///
/// 缓冲路径不会拿空体来解（`decode_response_body` 先挡了一道），
/// 但函数自己的契约要写清楚——免得将来有人把空体喂进来得到一个「成功」。
async test "decode_gzip rejects an empty body" {
  let empty : Result[Bytes, TransportError] = Ok(decode_gzip(b"")) catch {
    error => Err(error)
  }
  assert_true(empty is Err(Malformed(_)))
}

///|
/// 不是 gzip 的字节：报 `Malformed`（响应体与它声称的编码不符），
/// 不把没解压的字节当成功交出去。
async test "decode_gzip rejects bytes that are not a gzip stream" {
  let plain : Result[Bytes, TransportError] = Ok(
    decode_gzip(b"not compressed at all"),
  ) catch {
    error => Err(error)
  }
  assert_true(plain is Err(Malformed(_)))
  // 只有 gzip 的 10 字节头、没有任何数据块：读到这里数据就断了，同样报错
  let header_only : Result[Bytes, TransportError] = Ok(
    decode_gzip(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"),
  ) catch {
    error => Err(error)
  }
  assert_true(header_only is Err(Malformed(_)))
}

///|
/// `declares_gzip` 只认「整份值就是 gzip」：大小写与空白无关，
/// 别的编码与多值列表都不认（认宽了就等于把没解压的字节当实体字节交出去）。
test "declares_gzip only accepts a plain gzip content-encoding" {
  assert_true(declares_gzip(gzip_headers()))
  assert_true(
    declares_gzip(@headers.Headers::new().set("Content-Encoding", " GZip ")),
  )
  assert_false(
    declares_gzip(@headers.Headers::new().set("Content-Encoding", "br")),
  )
  assert_false(
    declares_gzip(@headers.Headers::new().set("Content-Encoding", "gzip, br")),
  )
  assert_false(declares_gzip(@headers.Headers::new()))
}
