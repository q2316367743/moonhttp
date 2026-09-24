// 取消作用域：把「一次可被取消的 I/O」放进可中断的子任务。
//
// 为什么需要它：`moonbitlang/async` 的取消是**协程级**的（`Task::cancel`），
// 而取消一条别人正在等的请求需要一个任务句柄——句柄只在 `spawn` 之后才有。
// 这里把 token 与子任务连起来：token 被取消 → 登记的子任务被 cancel →
// 挂起中的 connect / read / write 立刻中断。
//
// 落点只有三处，都在本包内（对底层库的依赖只允许出现在 transport 里）：
// - `AsyncHttpTransport::send`：每一跳的建连、写头、写 body、等响应头；
// - `read_or_fail`：响应体每次读取（按块读、读全量与 SSE 都经过它）；
// - `ResponseBody`：把「取消即关闭这条连接」登记到 token 上。
//
// 语义与注意事项见 `docs/12-cancellation.md`。

///|
/// 跑 `f`，并在 `token` 取消时中断它。
///
/// - `token` 是 `None`：直接跑，不建任务组、零额外开销；
/// - `f` 正常结束：原样返回它的结果；`f` 自己抛的错原样向外抛，不做包装；
/// - token 取消了这次操作：抛 `TransportError::Cancelled`。
///
/// 为什么不是「执行到检查点时看一眼 token 有没有取消」：检查只在执行到检查点时
/// 有效，而请求卡在等首字节 / 建连时根本没有下一个检查点——那正是最需要取消的
/// 场景。协程级取消的落点是**挂起点**，所以挂起中的 socket 动作会被真的中断
/// （`@async.with_timeout` 用的就是同一套机制，超时就是「定时取消」）。
///
/// 一条关键性质：被取消的是**这里 spawn 的子任务**，不是调用方协程。所以取消
/// 之后调用方不会被「粘住」（取消是被取消任务的粘性状态），它拿到的只是一个
/// 普通错误，可以接着发下一个请求。
async fn[T] with_cancel_scope(
  token : @config.CancelToken?,
  f : async () -> T raise TransportError,
) -> T raise TransportError {
  match token {
    None => f()
    Some(token) =>
      // `try` 是为了把错误类型收回来：`Task::wait`（以及它背后的任务组）会
      // 等待任意任务，错误类型被放宽到 `Error`，这里显式收敛回 `TransportError`。
      // 取消信号不在此列——`catch` 抓不住它（见 moonbitlang/async 的 README），
      // 所以调用方自己的取消照常向上冒，不会被这段兜底改写成传输层错误。
      try
        @async.with_task_group() <| group => {
          let task = group.spawn(() => f())
          // 先登记、再等待。已经取消的 token 会在这里立刻 cancel 掉子任务：
          // 取消落在两段 I/O 之间（重定向的两跳之间就是一个真实的时间窗）时，
          // 这一段必须马上断，否则它会照常发出去。
          let ticket = token.attach(fn() { task.cancel() })
          defer token.detach(ticket)
          task.wait()
        }
      catch {
        // 子任务被取消 → 对外是「取消」，不是「网络失败」。
        @async.TaskCancelled => raise TransportError::Cancelled
        error => raise narrow_transport_error(error)
      }
  }
}

///|
/// 把任务边界上漏出来的错误收敛回传输层错误。
///
/// 本包只抛 `TransportError`，逐个变体匹配是为了原样透传；走到兜底说明有不认识的
/// 错误从被包装的操作里漏了出来（或者底层库换了一套错误），按本包既有的口径
/// 归到网络层并保留原文——与 `send_head` / `read_or_fail` 的兜底一致。
fn narrow_transport_error(error : Error) -> TransportError {
  match error {
    TransportError::Timeout => TransportError::Timeout
    TransportError::Network(message) => TransportError::Network(message)
    TransportError::Unsupported(message) => TransportError::Unsupported(message)
    TransportError::Cancelled => TransportError::Cancelled
    error => TransportError::Network(error.to_string())
  }
}

///|
/// `token` 已经取消时给出 `TransportError::Cancelled`，否则 `None`。
///
/// 给读取路径做「取消发生在两次读取之间」的检查用：读方法是普通函数，
/// 拿不到取消信号，只能自己问一句 token——这段窗口里没有 I/O 可中断，
/// 但语义上必须报取消，不能把已关闭的流当成正常 EOF。
fn cancelled_failure(token : @config.CancelToken?) -> TransportError? {
  match token {
    Some(token) =>
      if token.is_cancelled() {
        Some(TransportError::Cancelled)
      } else {
        None
      }
    None => None
  }
}
