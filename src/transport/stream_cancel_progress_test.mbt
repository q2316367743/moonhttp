// 读全量 + 下载进度回调里的取消：**下一轮读之前**必须停。
//
// 为什么单列一条不依赖网络的用例：取消会同步关闭连接，TLS 的 `SSL` 对象
// 随连接一起释放；如果 `drain_into` 在回调返回后继续读，httpconn 就会在
// 已释放的 TLS 上做 `SSL_read`（真机上表现为 SIGSEGV，见 docs/13）。
// 这里用「关闭后再读就 abort」的假 reader 把同一个时序搬到内存里：
// 回归时这条用例会直接失败，而不是让整个测试进程崩掉。

///|
/// 关闭后不许再读的读取器：`alive` 由释放回调翻转，`_direct_read` 一旦
/// 看到它已经是 `false` 就 `abort`——正是「SSL 已释放还去读」的最小替身。
struct GuardedReader {
  data : Bytes
  mut offset : Int32
  buf : @io.ReaderBuffer
  alive : Array[Bool]
  /// 真正被读了几次（跨结构体副本共享，用数组而不是 mut 字段）
  count : Array[Int32]
}

///|
fn GuardedReader::new(
  data : Bytes,
  alive : Array[Bool],
  count : Array[Int32],
) -> GuardedReader {
  { data, offset: 0, buf: @io.ReaderBuffer::new(), alive, count, }
}

///|
impl @io.Reader for GuardedReader with fn _get_internal_buffer(
  self : GuardedReader,
) -> @io.ReaderBuffer {
  self.buf
}

///|
impl @io.Reader for GuardedReader with fn _direct_read(
  self : GuardedReader,
  dst : FixedArray[Byte],
  offset~ : Int32,
  max_len~ : Int32,
) -> Int32 {
  if !self.alive[0] {
    abort("read after close: 连接已释放，这一轮读不该发生")
  }
  self.count[0] = self.count[0] + 1
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
/// 进度回调里取消：错误按取消分类，且底层 reader 只被读过一次。
async test "cancelling in the download progress callback stops before the next read" {
  let alive = [true]
  let count = [0]
  let reader = GuardedReader::new(b"hello wire", alive, count)
  let controller = @abort.AbortController::new()
  let body = @transport.ResponseBody::open_wire(
    reader,
    fn() { alive[0] = false },
    timeout=None,
    total=Some(10),
    signal=Some(controller.signal()),
  )
  let seen : Array[Int32] = []
  let (bytes, failure) = body.read_all_partial(on_progress=fn(event) {
    seen.push(event.loaded)
    controller.abort(reason="进度回调里取消")
  })
  assert_eq(seen, [10])
  // 第一块已经收下（失败现场要保住），但绝没有第二轮读
  assert_eq(bytes, b"hello wire")
  assert_eq(count[0], 1)
  match failure {
    Some(@transport.TransportError::Cancelled(reason)) =>
      assert_eq(reason, Some("进度回调里取消"))
    _ => abort("期望取消，实际不是 Cancelled")
  }
}
