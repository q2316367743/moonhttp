// chunked 的渲染（发送侧）：`chunked.mbt` 解码状态机的对偶。
//
// 流式上传（docs/20）在没有 `content_length` 时用它把请求体按 chunked 编码
// 发出（RFC 9112 §7.1）。与请求头渲染同理，全部走 write_byte / write_bytes，
// 不碰 buffer 的 write_string*（那是 UTF-16LE，上不了线协议）。

///|
/// 十六进制写出 chunk-size（小写）。递归先写高位，天然没有前导零。
/// 解码侧大小写都收（`parse_chunk_size`）；发送侧统一小写，与 curl / nginx
/// 等常见实现的输出一致。
fn write_hex_size(buf : @buffer.Buffer, size : Int) -> Unit {
  fn write_digits(value : Int) -> Unit {
    if value >= 16 {
      write_digits(value / 16)
    }
    let digit = value % 16
    let code = if digit < 10 {
      '0'.to_int() + digit
    } else {
      'a'.to_int() + digit - 10
    }
    buf.write_byte(code.to_byte())
  }
  write_digits(size)
}

///|
/// 渲染一个数据帧：`hex(chunk-size) CRLF chunk-data CRLF`。
///
/// 空数据在这里直接拒绝：零长度帧在 chunked 里就是终止帧，把空块渲染出去
/// 等于把报文提前截断。调用方（httpconn 的泵循环）也会跳过空块，
/// 这条是渲染侧的最后防线（与 `write_ascii` 拒绝非 ASCII 同一思路）。
pub fn render_chunk_frame(data : Bytes) -> Bytes raise ParseError {
  if data.length() == 0 {
    raise ParseError::Malformed("chunked 数据帧不能是空字节")
  }
  let buf = @buffer.Buffer::Buffer(size_hint=data.length() + 16)
  write_hex_size(buf, data.length())
  buf.write_byte(b'\r')
  buf.write_byte(b'\n')
  buf.write_bytes(data)
  buf.write_byte(b'\r')
  buf.write_byte(b'\n')
  buf.to_bytes()
}

///|
/// 终止帧：`0 CRLF CRLF`。trailer 节为空——本项目不发 trailer，
/// 解码侧（`ChunkDecoder`）也按既定口径把 trailer 丢弃（见 chunked.mbt）。
pub fn render_last_chunk() -> Bytes {
  let buf = @buffer.Buffer::Buffer(size_hint=5)
  buf.write_byte(b'0')
  buf.write_byte(b'\r')
  buf.write_byte(b'\n')
  buf.write_byte(b'\r')
  buf.write_byte(b'\n')
  buf.to_bytes()
}
