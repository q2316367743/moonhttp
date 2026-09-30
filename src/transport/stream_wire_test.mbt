// open_wire（自研栈的响应体来源）的读语义测试。
//
// FixedReader 同时是一次**前提验证**：在 moonbitlang/async 的包外实现
// `@io.Reader`（`ReaderBuffer::new()` 公开、trait 的两个必需方法未标内部）。
// 自研传输层 httpconn 的连接流靠的就是这条路——如果哪天上游收紧了这两点，
// 这份测试会第一个失败，方案退路见 docs/18。

///|
/// 测试用的定长读取器：一次性交出一段字节，EOF 返回 0。
/// 实现路径与 httpconn 的连接流完全一致：`ReaderBuffer` 当内部缓冲，
/// `_direct_read` 负责从「真实来源」（这里是内存，真实场景是 TCP/TLS）拉字节。
struct FixedReader {
  data : Bytes
  mut offset : Int
  buf : @io.ReaderBuffer
}

///|
fn FixedReader::new(data : Bytes) -> FixedReader {
  { data, offset: 0, buf: @io.ReaderBuffer::new(), }
}

///|
/// 包外实现 `@io.Reader` 的关键一步：内部缓冲用公开的 `ReaderBuffer::new()`。
/// 默认方法（read / read_some / read_until / …）都从这一个函数拿缓冲。
impl @io.Reader for FixedReader with fn _get_internal_buffer(self : FixedReader) -> @io.ReaderBuffer {
  self.buf
}

///|
/// 从内存里搬一段到调用方的目标缓冲；返回 0 表示 EOF。
/// 异步性来自 trait 声明，实现侧照旧写 `fn`。
impl @io.Reader for FixedReader with fn _direct_read(
  self : FixedReader,
  dst : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  let remaining = self.data.length() - self.offset
  if remaining == 0 || max_len == 0 {
    return 0
  }
  let take = if max_len < remaining { max_len } else { remaining }
  for i in 0..<take {
    dst[offset + i] = self.data[self.offset + i]
  }
  self.offset += take
  take
}

///|
/// open_wire 交出的流：read_some 逐段读、EOF 返回 None 且自动关连接。
async test "wire body reads to eof and closes the connection" {
  let mut closed = 0
  let reader : &@io.Reader = FixedReader::new(b"hello wire")
  let body = @transport.ResponseBody::open_wire(
    reader,
    fn() { closed += 1 },
    timeout=Some(1000),
    total=Some(10),
    signal=None,
  )
  assert_eq(body.read_some(max_len=5), Some(b"hello"))
  assert_eq(body.read_some(), Some(b" wire"))
  // EOF：返回 None，连接自动关闭且只关一次
  assert_eq(body.read_some(), None)
  assert_eq(closed, 1)
  assert_eq(body.read_some(), None)
  assert_eq(closed, 1)
}

///|
/// read_until 与内存体同一条语义：分隔符被消费、不进返回值；
/// EOF 前的残余当作最后一段。
async test "wire body read_until matches the shared semantics" {
  let mut closed = 0
  let reader : &@io.Reader = FixedReader::new(b"a: 1\nb: 2\n")
  let body = @transport.ResponseBody::open_wire(
    reader,
    fn() { closed += 1 },
    timeout=None,
    total=None,
    signal=None,
  )
  assert_eq(body.read_until("\n"), Some("a: 1"))
  assert_eq(body.read_until("\n"), Some("b: 2"))
  // 没有分隔符的 EOF：最后一段交出去，流结束
  assert_eq(body.read_until("\n"), None)
  assert_eq(closed, 1)
}

///|
/// 进来就已取消的信号：立刻关流，读取报 Cancelled 而不是安静 EOF——
/// 「取消不能被当成 EOF」这条兜底在这里生效。
async test "already-cancelled signal closes the wire body up front" {
  let mut closed = 0
  // AbortSignal::abort() 直接给出一个已取消的信号
  let signal = @abort.AbortSignal::abort()
  let reader : &@io.Reader = FixedReader::new(b"never read")
  let body = @transport.ResponseBody::open_wire(
    reader,
    fn() { closed += 1 },
    timeout=None,
    total=None,
    signal=Some(signal),
  )
  assert_eq(closed, 1)
  let error = try {
    ignore(body.read_some())
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@transport.TransportError::Cancelled(_)))
}
