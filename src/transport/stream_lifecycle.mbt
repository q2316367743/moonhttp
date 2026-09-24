// stream.mbt 拆出来的另一半：响应体的**构造与释放**，以及挂在取消句柄上的那条
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
    cancel_token: None,
    cancel_ticket: None,
  }
}

///|
/// 用一条已经收到响应头的真实连接构造响应体。
/// 只有本包内的 `AsyncHttpTransport` 会用它——连接的生命周期从这里
/// 交给响应体，读到 EOF 或 `close()` 时才会关闭。
///
/// `total` 是响应头里的 `Content-Length`，取不到就是 `None`。
/// `cancel_token` 是这次请求的取消句柄：给了它就同时登记「取消即关闭」——
/// 调用方取消之后往往就不再读了，没有这一步连接要拖到显式 `close()` 才释放。
/// 已经取消的 token 会立刻触发这条登记，正好对应「拿到的流已经死了」
/// （随后任何读取都会报 `Cancelled`，而不是安静地 EOF）。
fn ResponseBody::open(
  client : @http.Client,
  timeout : Int?,
  total : Int?,
  cancel_token : CancelToken?,
) -> ResponseBody {
  let body : ResponseBody = {
    inner: BodyInner::Http(client),
    timeout,
    total,
    cancel_token,
    cancel_ticket: None,
  }
  match cancel_token {
    Some(token) =>
      body.cancel_ticket = Some(token.attach(fn() { body.close() }))
    None => ()
  }
  body
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
    Http(client) => client.close()
    _ => ()
  }
  self.inner = BodyInner::Closed
  // 注销挂到 token 上的那条「取消即关闭」：连接已经关了，再留着这条登记
  // 只会让 token 一直握着这个响应体。取消触发的那个 close 也会走到这里——
  // 那时登记已经被整组取走，注销是个越界空操作（detach 容忍这一点）。
  match self.cancel_ticket {
    Some(ticket) =>
      match self.cancel_token {
        Some(token) => token.detach(ticket)
        None => ()
      }
    None => ()
  }
  self.cancel_ticket = None
}
