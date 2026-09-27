// 取消作用域的用例：钉住「进来就已取消」这条兜底（取消落在两段 I/O 之间时，
// 重定向的两跳之间就是真实的一例）。
//
// 白盒：`with_abort_scope` 是包私有的，只有编进本包的 wbtest 能直接调它。
// 「打断挂起中的 I/O」那件事必须起真实连接，用例在根包的真机测试里
// （`src/cancel_test.mbt` / `src/cancel_stream_test.mbt`）；这里只钉机制里那个
// **不依赖网络**的分支——旧实现靠 `attach` 到已取消的 token 立刻触发来兜底，
// 现在这份兜底改由登记点显式检查，用例也就落在这里。

///|
/// 进来就取消：`f` 一次都不会被调用，直接抛 `Cancelled`（载荷就是取消理由）。
///
/// 少了这条检查，「重定向第二跳照常发出去」那个漏洞会回来（信号上的登记在
/// 已取消时不会补触发，见 `src/abort/abort.mbt` 的 `attach`）。
async test "an already aborted signal fails the scope without running it" {
  let controller = @abort.AbortController::new()
  controller.abort(reason="进来就取消")
  let ran : Array[Bool] = [false]
  let error = try {
    ignore(
      with_abort_scope(Some(controller.signal()), () => {
        ran[0] = true
        1
      }),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_false(ran[0])
  assert_true(error is Some(TransportError::Cancelled(_)))
  // 理由随错误上来：信号不在配置里，上层没有别的地方能找到它
  let reason = match error {
    Some(TransportError::Cancelled(reason)) => reason
    _ => None
  }
  assert_eq(reason, Some("进来就取消"))
}

///|
/// 还活着的信号只把操作包一层：结果原样返回，操作真的跑了。
/// 顺带钉住「信号为 `None` 时直跑」那条零额外开销的路径。
async test "a live signal runs the operation and passes its result through" {
  let controller = @abort.AbortController::new()
  assert_eq(with_abort_scope(Some(controller.signal()), () => 42), 42)
  assert_eq(with_abort_scope(None, () => 7), 7)
}
