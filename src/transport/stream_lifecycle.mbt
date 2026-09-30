// stream.mbt 拆出来的另一半：响应体的**构造与释放**，以及挂在取消信号上的那条
// 「取消即关闭」登记。
//
// 为什么单独一个文件：AGENTS.md RL-04 对子包文件的上限是 300 行，加上取消之后
// stream.mbt 会超限；「这条连接什么时候被创建、什么时候被释放」正好是能整体搬走的
// 一块——读语义（内存体与连接体的分支、超时、逐块读）留在 stream.mbt。
//
// 连接的所有权口径见 `docs/05-transport.md` 的「`ResponseBody` 契约」，
// 取消相关的语义见 `docs/12-cancellation.md`。

///|
/// 用内存字节构造响应体。Mock 传输层与自定义实现用它造出
/// 「不是网络来的」响应体，读语义与真实连接一致。
pub fn ResponseBody::from_bytes(data : Bytes) -> ResponseBody {
  {
    inner: BodyInner::Memory({ data, offset: 0, }),
    timeout: None,
    // 完整字节在手，长度总是已知：下载进度的 total 就是它。
    total: Some(data.length()),
    // 内存体没有连接要释放，也就没有「取消即关闭」这回事：
    // 取消对它的影响由上层（请求进入管线时的预检查）表达。
    signal: None,
    signal_ticket: None,
  }
}

///|
/// 用自研传输层（httpconn）的连接流构造响应体：`reader` 是已按 HTTP 分帧
/// 切好的读端（chunked / content-length / close-delimited 都在它底下解好），
/// `close` 负责释放底层连接（TLS + TCP）。连接的生命周期从这里交给响应体，
/// 读到 EOF 或 `close()` 时才会关闭。
///
/// `timeout` 约束**单次读取**、`signal` 登记「取消即关闭」、进来就已取消的
/// 信号立刻关流——随后任何读取都会报 `Cancelled` 而不是安静地 EOF。这份检查
/// 必须自己写——信号上的登记在已取消时不会补触发，见 `src/abort/abort.mbt`
/// 的 `attach`。`close` 应当幂等：取消触发的关闭与显式 `close()` 可能只差一拍。
pub fn ResponseBody::open_wire(
  reader : &@io.Reader,
  close : () -> Unit,
  timeout~ : Int?,
  total~ : Int?,
  signal~ : @abort.AbortSignal?,
) -> ResponseBody {
  let body : ResponseBody = {
    inner: BodyInner::Wire({ reader, close, }),
    timeout,
    total,
    signal,
    signal_ticket: None,
  }
  register_cancel_close(body)
  body
}

///|
/// 「取消即关闭」的登记：`open_wire` 的兜底。
/// **进来就已经取消**的信号在这里显式处理：立刻关掉，随后任何读取都会报
/// `Cancelled` 而不是安静地 EOF。这份检查必须自己写——信号上的登记在
/// 已取消时不会补触发，见 `src/abort/abort.mbt` 的 `attach`。
fn register_cancel_close(body : ResponseBody) -> Unit {
  match body.signal {
    Some(signal) =>
      if signal.aborted() {
        body.close()
      } else {
        // 上面查过了，所以这里的登记一定拿到票号（`attach` 只在已取消时返回无票）。
        body.signal_ticket = Some(signal.attach(fn() { body.close() }))
      }
    None => ()
  }
}

///|
/// 复制一份「从头开始读」的响应体。
///
/// Mock 传输层要能把同一个响应交给多次请求，就不能共用已经消费过的游标，
/// 所以它每服务一次都会 `rewind()` 一份。真实连接不可复制，返回 `None`——
/// 使用方把网络来的响应体配给 Mock 是使用错误，应当响亮失败。
fn ResponseBody::rewind(self : ResponseBody) -> ResponseBody? {
  match self.inner {
    Memory(memory) => Some(ResponseBody::from_bytes(memory.data))
    _ => None
  }
}

///|
/// 关闭流并释放底层连接。幂等：重复调用只生效一次。
///
/// 只读了半截就停止（例如 SSE 收到想结束就断开）时必须显式调用它，
/// 否则连接会一直挂着。
pub fn ResponseBody::close(self : ResponseBody) -> Unit {
  match self.inner {
    // close 的幂等性靠「立刻置 Closed」保证：回调本身不必防重入。
    // 字段里的函数值要先解出来再调（直接 wire.close() 会被当成方法调用）。
    Wire(wire) => {
      let close = wire.close
      close()
    }
    _ => ()
  }
  self.inner = BodyInner::Closed
  // 注销挂到信号上的那条「取消即关闭」：连接已经关了，再留着这条登记
  // 只会让信号一直握着这个响应体。取消触发的那个 close 也会走到这里——
  // 那时登记已经被整组取走，注销是个越界空操作（detach 容忍这一点）。
  match self.signal_ticket {
    Some(ticket) =>
      match self.signal {
        Some(signal) => signal.detach(ticket)
        None => ()
      }
    None => ()
  }
  self.signal_ticket = None
}
