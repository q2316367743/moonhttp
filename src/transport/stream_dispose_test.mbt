// dispose 双通道的语义钉子（docs/21）：读到 EOF 是 `Finished`
// （连接池据此判「体读完了，可以议价复用」），半途放弃、读失败、取消
// 一律 `Abandoned`（毒化，绝不回池）。释放只走一次（幂等）。
// FixedReader 复用 stream_wire_test.mbt 的定义（同一个黑盒测试包）。

///|
/// 读一次就炸的 Reader：模拟「读到一半连接断了」。raise 通道与真实
/// 连接一致（Tcp::read 的失败同样从 _direct_read 冒出来）。
struct BoomReader {
  buf : @io.ReaderBuffer
  mut reads : Int32
}

///|
fn BoomReader::new() -> BoomReader {
  { buf: @io.ReaderBuffer::new(), reads: 0, }
}

///|
impl @io.Reader for BoomReader with fn _get_internal_buffer(self : BoomReader) -> @io.ReaderBuffer {
  self.buf
}

///|
impl @io.Reader for BoomReader with fn _direct_read(
  self : BoomReader,
  dst : FixedArray[Byte],
  offset~ : Int32,
  max_len~ : Int32,
) -> Int32 {
  ignore(dst)
  ignore(offset)
  ignore(max_len)
  self.reads = self.reads + 1
  raise Failure::Failure("boom")
}

///|
/// 释放回调的记录器：calls 里按序收 BodyEnd。
fn tracked() -> (Array[@transport.BodyEnd], (@transport.BodyEnd) -> Unit) {
  let calls : Array[@transport.BodyEnd] = []
  (calls, fn(end) { calls.push(end) })
}

///|
async test "reading to EOF releases as Finished and stays idempotent" {
  let (calls, dispose) = tracked()
  let body = @transport.ResponseBody::open_wire_dispose(
    FixedReader::new(b"hello"),
    dispose,
    timeout=None,
    total=Some(5),
    signal=None,
  )
  assert_eq(body.read_some(), Some(b"hello"))
  assert_eq(body.read_some(), None)
  assert_eq(calls, [@transport.BodyEnd::Finished])
  // EOF 已经释放过，再 close 不得触发第二次（池最怕重复回收）
  body.close()
  assert_eq(calls, [@transport.BodyEnd::Finished])
}

///|
test "explicit close releases as Abandoned" {
  let (calls, dispose) = tracked()
  let body = @transport.ResponseBody::open_wire_dispose(
    FixedReader::new(b"hello"),
    dispose,
    timeout=None,
    total=Some(5),
    signal=None,
  )
  // 一个字节都没读就放弃：连接字节流停在开头，但「放弃」本身就是毒化
  body.close()
  assert_eq(calls, [@transport.BodyEnd::Abandoned])
}

///|
async test "read failure releases as Abandoned" {
  let (calls, dispose) = tracked()
  let body = @transport.ResponseBody::open_wire_dispose(
    BoomReader::new(),
    dispose,
    timeout=None,
    total=None,
    signal=None,
  )
  let error = try {
    ignore(body.read_some())
    None
  } catch {
    error => Some(error)
  }
  // 读失败被收敛成 Network（read_or_fail 的口径），且流已被毒化关闭
  assert_true(error is Some(Network(_)))
  assert_eq(calls, [@transport.BodyEnd::Abandoned])
}

///|
async test "read_all releases as Finished, failed read_all_partial as Abandoned" {
  let (done_calls, done_dispose) = tracked()
  let body = @transport.ResponseBody::open_wire_dispose(
    FixedReader::new(b"hello world"),
    done_dispose,
    timeout=None,
    total=Some(11),
    signal=None,
  )
  assert_eq(body.read_all(), b"hello world")
  assert_eq(done_calls, [Finished])
  let (failed_calls, failed_dispose) = tracked()
  let broken = @transport.ResponseBody::open_wire_dispose(
    BoomReader::new(),
    failed_dispose,
    timeout=None,
    total=None,
    signal=None,
  )
  // read_all_partial 的契约：失败不抛，交出现场 + 错误；连接照样毒化
  let (bytes, failure) = broken.read_all_partial()
  assert_eq(bytes, b"")
  assert_true(failure is Some(Network(_)))
  assert_eq(failed_calls, [Abandoned])
}

///|
test "cancelled signal releases as Abandoned" {
  let (calls, dispose) = tracked()
  let controller = @abort.AbortController::new()
  controller.abort(reason="gone")
  // 进来就已取消的信号：open_wire_dispose 立刻关流（register_cancel_close 兜底）
  let body = @transport.ResponseBody::open_wire_dispose(
    FixedReader::new(b"hello"),
    dispose,
    timeout=None,
    total=Some(5),
    signal=Some(controller.signal()),
  )
  // 断言用的就是「构造即释放」这件事本身，绑定本身不再被消费
  ignore(body)
  assert_eq(calls, [@transport.BodyEnd::Abandoned])
}
