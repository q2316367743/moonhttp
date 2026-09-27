// 取消原语（`AbortController` / `AbortSignal`）的状态机用例。
//
// 全是同步用例：本包不认识 async，也不碰网络——「取消的状态与登记的回调」与
// 「打断一次真实的挂起 I/O」是两件事，后者在根包的真机用例里验证
// （`src/cancel_test.mbt`）。契约见 `docs/12-cancellation.md`。

///|
/// 新控制器的信号是未取消状态，也没有理由。
test "a new controller is not aborted" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  assert_false(signal.aborted())
  assert_eq(signal.reason(), None)
}

///|
/// 取消之后状态翻转；理由就是传进来的 reason，没传就是 `None`——
/// 默认文案属于错误层（见 `docs/04-errors.md`），信号自己不编一个。
test "abort flips the state and keeps the reason" {
  let controller = @abort.AbortController::new()
  controller.abort()
  assert_true(controller.signal().aborted())
  assert_eq(controller.signal().reason(), None)
  let controller = @abort.AbortController::new()
  controller.abort(reason="用户点了停止")
  assert_true(controller.signal().aborted())
  assert_eq(controller.signal().reason(), Some("用户点了停止"))
}

///|
/// 一次性：第二次 `abort` 既不改理由，也不重新触发回调。
test "abort is one-shot and idempotent" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  let calls : Array[String] = []
  ignore(signal.attach(fn() { calls.push("first") }))
  controller.abort(reason="第一次")
  controller.abort(reason="第二次")
  assert_eq(signal.reason(), Some("第一次"))
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], "first")
}

///|
/// 同一个控制器给出去的信号共享同一份状态：取消一次，两个信号都看得到。
/// 这是「控制器留在发起方手里、信号到处传」这条分工成立的前提。
test "signals handed out by one controller share state" {
  let controller = @abort.AbortController::new()
  let first = controller.signal()
  let second = controller.signal()
  controller.abort(reason="共享")
  assert_true(first.aborted())
  assert_true(second.aborted())
  assert_eq(second.reason(), Some("共享"))
}

///|
/// 多个登记按登记顺序触发：一次请求可能有「中断 I/O」与「释放连接」两件事，
/// 顺序确定才好推理（也不依赖它，但顺序乱了要能被发现）。
test "attached handles run in registration order" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  let calls : Array[Int] = []
  ignore(signal.attach(fn() { calls.push(1) }))
  ignore(signal.attach(fn() { calls.push(2) }))
  controller.abort()
  assert_eq(calls.length(), 2)
  assert_eq(calls[0], 1)
  assert_eq(calls[1], 2)
}

///|
/// 注销之后回调不再被触发；票号递增，注销的是认领的那一个。
test "detach unregisters a handle" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  let calls : Array[Int] = []
  let dropped = signal.attach(fn() { calls.push(1) })
  let kept = signal.attach(fn() { calls.push(2) })
  assert_eq(dropped, 0)
  assert_eq(kept, 1)
  signal.detach(dropped)
  controller.abort()
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], 2)
}

///|
/// **已经取消的信号上登记既不触发、也不保留**（与 JS 的 `addEventListener`
/// 在 `aborted` 之后一致），返回「无票」。
///
/// 这条与旧的 `CancelToken` 不同：以前靠「登记即补触发」兜住「取消晚一步」，
/// 现在这份兜底由登记点**自己先查 `aborted()`** 承担（重定向两跳之间、
/// 两次读取之间都靠它，见 `docs/12-cancellation.md` 的「两条兜底」）。
test "attaching to an aborted signal neither fires nor is retained" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  controller.abort()
  let calls : Array[Int] = []
  let ticket = signal.attach(fn() { calls.push(1) })
  assert_eq(calls.length(), 0)
  // 这次登记没有槽位，票号是「无票」；注销它（以及任何越界票号）都不该出问题
  assert_eq(ticket, -1)
  signal.detach(ticket)
  signal.detach(99)
  signal.detach(-1)
  assert_true(signal.aborted())
}

///|
/// 取消触发的回调里可以注销别的登记——真实路径上就会发生
/// （`ResponseBody::close` 会注销自己）。取消时句柄数组已经被整组取走，
/// 这些注销都是越界空操作：不能 panic，也不能影响同时登记的其他句柄。
test "a handle may unregister itself while being called" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  let calls : Array[Int] = []
  // 票号要等第二个登记之后才有值，所以经一个单元数组传进去（闭包按值捕获）。
  let second_ticket : Array[Int] = [0]
  ignore(
    signal.attach(fn() {
      calls.push(1)
      signal.detach(second_ticket[0])
    }),
  )
  second_ticket[0] = signal.attach(fn() { calls.push(2) })
  controller.abort()
  assert_eq(calls.length(), 2)
  assert_eq(calls[0], 1)
  assert_eq(calls[1], 2)
}

///|
/// 同一个信号可以挂到多个请求上：登记彼此独立，一次 `abort` 全部生效。
test "one signal can serve several registrations" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  let calls : Array[Int] = []
  for i = 0; i < 3; i = i + 1 {
    ignore(signal.attach(fn() { calls.push(i) }))
  }
  controller.abort()
  assert_eq(calls.length(), 3)
}

///|
/// 静态构造：`AbortSignal::abort()` 出生就是已取消状态，理由原样带上
/// （对应 JS 的 `AbortSignal.abort(reason)`）。
test "the static abort builds an already aborted signal" {
  let bare = @abort.AbortSignal::abort()
  assert_true(bare.aborted())
  assert_eq(bare.reason(), None)
  let with_reason = @abort.AbortSignal::abort(reason="整体超时")
  assert_true(with_reason.aborted())
  assert_eq(with_reason.reason(), Some("整体超时"))
  // 出生即已取消，所以登记同样不触发
  let calls : Array[Int] = []
  assert_eq(with_reason.attach(fn() { calls.push(1) }), -1)
  assert_eq(calls.length(), 0)
}

///|
/// `throw_if_aborted` 对应 JS 的 `throwIfAborted`：没取消是空操作，
/// 已取消抛 `AbortError`，载荷就是取消理由（没给理由时是 `None`）。
test "throw_if_aborted raises AbortError with the reason" {
  let controller = @abort.AbortController::new()
  let signal = controller.signal()
  // 没取消：什么都不做，也不抛
  signal.throw_if_aborted()
  controller.abort(reason="别发了")
  let raised = try {
    signal.throw_if_aborted()
    None
  } catch {
    @abort.AbortError::Aborted(reason) => Some(reason)
  }
  assert_eq(raised, Some(Some("别发了")))
  // 取消时没给理由：载荷是 None（而不是「没抛」）
  let bare = @abort.AbortSignal::abort()
  let raised = try {
    bare.throw_if_aborted()
    None
  } catch {
    @abort.AbortError::Aborted(reason) => Some(reason)
  }
  assert_eq(raised, Some(None))
}
