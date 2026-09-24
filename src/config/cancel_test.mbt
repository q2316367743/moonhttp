// 取消句柄（`CancelToken`）的状态机与配置合并。
//
// 全是同步用例：这一层不认识 async，也不碰网络——「取消的状态与登记的回调」
// 与「打断一次真实的挂起 I/O」是两件事，后者在根包的真机用例里验证
// （`src/cancel_test.mbt`）。契约见 `docs/12-cancellation.md`。

///|
/// 新 token 是未取消状态，也没有理由。
test "a new token is not cancelled" {
  let token = @config.CancelToken::new()
  assert_false(token.is_cancelled())
  assert_eq(token.reason(), None)
}

///|
/// 取消之后状态翻转；理由就是传进来的 message，没传就是 `None`——
/// 默认文案属于错误层（见 `docs/04-errors.md`），token 自己不编一个。
test "cancel flips the state and keeps the message" {
  let token = @config.CancelToken::new()
  token.cancel()
  assert_true(token.is_cancelled())
  assert_eq(token.reason(), None)
  let token = @config.CancelToken::new()
  token.cancel(message="用户点了停止")
  assert_true(token.is_cancelled())
  assert_eq(token.reason(), Some("用户点了停止"))
}

///|
/// 一次性：第二次 `cancel` 既不改理由，也不重新触发回调。
test "cancel is one-shot and idempotent" {
  let token = @config.CancelToken::new()
  let calls : Array[String] = []
  ignore(token.attach(fn() { calls.push("first") }))
  token.cancel(message="第一次")
  token.cancel(message="第二次")
  assert_eq(token.reason(), Some("第一次"))
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], "first")
}

///|
/// 多个登记按登记顺序触发：一次请求可能有「中断 I/O」与「释放连接」两件事，
/// 顺序确定才好推理（也不依赖它，但顺序乱了要能被发现）。
test "attached handles run in registration order" {
  let token = @config.CancelToken::new()
  let calls : Array[Int] = []
  ignore(token.attach(fn() { calls.push(1) }))
  ignore(token.attach(fn() { calls.push(2) }))
  token.cancel()
  assert_eq(calls.length(), 2)
  assert_eq(calls[0], 1)
  assert_eq(calls[1], 2)
}

///|
/// 注销之后回调不再被触发；票号递增，注销的是认领的那一个。
test "detach unregisters a handle" {
  let token = @config.CancelToken::new()
  let calls : Array[Int] = []
  let dropped = token.attach(fn() { calls.push(1) })
  let kept = token.attach(fn() { calls.push(2) })
  assert_eq(dropped, 0)
  assert_eq(kept, 1)
  token.detach(dropped)
  token.cancel()
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], 2)
}

///|
/// **已经取消的 token 上登记会立刻触发**——这不是顺手补的容错，而是取消语义的
/// 兜底：`cancel` 只通知得到当时登记过的句柄，而请求可能在两段 I/O 之间
/// （重定向的两跳之间就是一个真实的时间窗）才去登记。少了这条，取消晚一步
/// 就会让下一跳照常发出去。
test "attaching to a cancelled token runs the handle immediately" {
  let token = @config.CancelToken::new()
  token.cancel()
  let calls : Array[Int] = []
  let ticket = token.attach(fn() { calls.push(1) })
  assert_eq(calls.length(), 1)
  assert_eq(calls[0], 1)
  // 这次登记没有槽位，票号是「无票」；注销它（以及任何越界票号）都不该出问题
  assert_eq(ticket, -1)
  token.detach(ticket)
  token.detach(99)
  token.detach(-1)
  assert_true(token.is_cancelled())
}

///|
/// 取消触发的回调里可以注销别的登记——真实路径上就会发生
/// （`ResponseBody::close` 会注销自己）。取消时句柄数组已经被整组取走，
/// 这些注销都是越界空操作：不能 panic，也不能影响同时登记的其他句柄。
test "a handle may unregister itself while being called" {
  let token = @config.CancelToken::new()
  let calls : Array[Int] = []
  // 票号要等第二个登记之后才有值，所以经一个单元数组传进去（闭包按值捕获）。
  let second_ticket : Array[Int] = [0]
  ignore(
    token.attach(fn() {
      calls.push(1)
      token.detach(second_ticket[0])
    }),
  )
  second_ticket[0] = token.attach(fn() { calls.push(2) })
  token.cancel()
  assert_eq(calls.length(), 2)
  assert_eq(calls[0], 1)
  assert_eq(calls[1], 2)
}

///|
/// 同一个 token 可以挂到多个请求上（这是选单对象形态的一部分理由）：
/// 登记彼此独立，一次 `cancel` 全部生效。
test "one token can serve several registrations" {
  let token = @config.CancelToken::new()
  let calls : Array[Int] = []
  for i = 0; i < 3; i = i + 1 {
    ignore(token.attach(fn() { calls.push(i) }))
  }
  token.cancel()
  assert_eq(calls.length(), 3)
}

///|
/// 配置字段与渲染：`with_cancel_token` 写进 `cancel_token`，渲染成 `<token>`
/// （不带取消状态，否则同一份配置在不同时刻会渲染出不同字符串）。
test "cancel token is a config field and renders as a placeholder" {
  let config = @config.Config::new("/users").with_cancel_token(
    @config.CancelToken::new(),
  )
  assert_true(config.cancel_token is Some(_))
  assert_true(config.to_string().contains("cancel_token: <token>"))
}

///|
/// 合并走策略 2（`prefer_request`）：请求级提供就整体替换实例默认值，
/// 请求级没提供就沿用实例默认值——实例级 token 是「本实例发出的请求共用
/// 一个取消信号」的用法。
test "cancel token merges with prefer-request semantics" {
  let instance_token = @config.CancelToken::new()
  let request_token = @config.CancelToken::new()
  let instance = @config.Config::default().with_cancel_token(instance_token)
  // 请求级提供：用请求级那个（身份可辨认——取消它，合并结果就是取消状态）
  let merged = @config.merge_config(
    instance,
    @config.Config::new("/users").with_cancel_token(request_token),
  )
  request_token.cancel(message="请求级")
  assert_eq(merged.cancel_token.unwrap().reason(), Some("请求级"))
  // 请求级没提供：沿用实例默认值
  let merged = @config.merge_config(instance, @config.Config::new("/users"))
  instance_token.cancel(message="实例级")
  assert_eq(merged.cancel_token.unwrap().reason(), Some("实例级"))
}
