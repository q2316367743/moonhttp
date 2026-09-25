// 取消（`cancel_token`）在请求路径上的验收用例：起真机 server 验证「打断了什么」。
//
// 为什么必须用真实连接：取消的价值恰恰在「请求挂在某个 socket 动作上」的时候，
// 而 Mock 传输层是同步返回的、没有挂起点可中断（这一点在 `docs/12-cancellation.md`
// 的「Mock 不模拟取消中断」里写明）。句柄本身的状态机在
// `src/config/cancel_test.mbt` 里同步验证；流式入口的用例在
// `src/cancel_stream_test.mbt`。
//
// AGENTS.md RL-04 例外声明：本文件是根包（`src/` 根目录）的测试文件，随用例增加
// 突破 300 行，按 RL-04 为根包文件开出的例外处理——上限 1000 行，并在此声明。

///|
/// 起一个「收到请求后先挂住，过一会儿才回响应头」的本机 server，返回端口。
///
/// 把客户端钉在**等响应头**这个状态上：这是最需要取消的场景——对面一个字节都
/// 不吐，「执行到下一个检查点再看标志位」那类实现在这里根本没有检查点可查。
async fn slow_headers_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((_request, _body, conn) => {
      @async.sleep(3000)
      conn..send_response(200, "OK").flush()
      conn..write_string("late").end_response()
    })
  }
  port
}

///|
/// 起一个「立刻回 200 与一小段正文」的本机 server，返回端口。
/// 用来验证取消之后同一条协程还能正常发请求。
async fn ok_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((_request, _body, conn) => {
      conn..send_response(200, "OK").flush()
      conn..write_string("ok").end_response()
    })
  }
  port
}

///|
/// 起一个「立刻回响应头与一段正文，然后挂住」的本机 server，返回端口
/// （与 `error_test.mbt` 的 `stalling_server` 同型，这里固定用 200 与一段正文）。
async fn partial_then_stall_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((_request, _body, conn) => {
      conn..send_response(200, "OK").flush()
      conn..write_string("partial-body").flush()
      @async.sleep(3000)
      conn.end_response()
    })
  }
  port
}

///|
/// 在子任务里发一次请求，`delay` 毫秒后取消 token；返回请求的错误与耗时（毫秒）。
///
/// 「另一条协程来取消」正是真实的用法（UI 的停止按钮、看门狗），也是取消必须
/// 走协程级中断而不是同步标志位的原因。
async fn request_then_cancel(
  group : @async.TaskGroup[Unit],
  client : @moonhttp.Client,
  config : @moonhttp.Config,
  token : @moonhttp.CancelToken,
  delay : Int,
  message : String,
) -> (@moonhttp.HttpError, Int) {
  let outcome : Array[@moonhttp.HttpError?] = [None]
  let started = @async.now()
  let worker = group.spawn(() => {
    let error = try {
      ignore(client.request(config))
      None
    } catch {
      error => Some(error)
    }
    outcome[0] = error
  })
  group.spawn_bg(no_wait=true) <| () => {
    @async.sleep(delay)
    token.cancel(message~)
  }
  worker.wait()
  (outcome[0].unwrap(), (@async.now() - started).to_int())
}

///|
/// 已经取消的 token 让请求**什么都不做**：不发 I/O、不跑请求拦截器。
///
/// 这条不靠真机也能验（用 Mock 传输层），而它正是「取消语义与传输实现无关」
/// 的那一半：Mock 没有挂起可中断，但「已取消的请求不发出」照样成立。
async test "a cancelled token fails the request before anything happens" {
  let token = @moonhttp.CancelToken::new()
  token.cancel(message="提前取消")
  let mock = @transport.MockTransport::new(raw_response(200, "OK", "{}"))
  let transport : &@transport.Transport = mock
  let ran : Array[Bool] = [false]
  let interceptors = @moonhttp.Interceptors::new().use_request(config => {
    ran[0] = true
    config
  })
  let client = @moonhttp.Client::new(transport~, interceptors~)
  let error = try {
    ignore(
      client.request(@moonhttp.Config::new("/users").with_cancel_token(token)),
    )
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_true(error.is_cancelled())
  assert_eq(error.code(), @moonhttp.ErrorCode::Cancelled)
  // 与 axios 的 `ERR_CANCELED` 对齐，且和超时（ECONNABORTED）分得开
  assert_eq(error.code().to_string(), "ERR_CANCELED")
  // 取消时给的 message 原样成为错误描述
  assert_eq(error.message(), "提前取消")
  // 请求一个字节都没发出去，拦截器也没跑（拦截器可能带副作用）
  assert_eq(mock.request_count(), 0)
  assert_false(ran[0])
  assert_true(error.response() is None)
}

///|
/// 没给 message 时用库的默认文案（文案只在错误层，token 自己不编）。
async test "a cancelled token without a message uses the default wording" {
  let token = @moonhttp.CancelToken::new()
  token.cancel()
  let mock = @transport.MockTransport::new(raw_response(200, "OK", "{}"))
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let error = try {
    ignore(
      client.request(@moonhttp.Config::new("/users").with_cancel_token(token)),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_eq(error.unwrap().message(), "请求已取消")
}

///|
/// 请求挂在「等响应头」上时取消：**立刻**结束，而不是等对面那 3 秒。
///
/// 耗时断言是这条用例的重点——它把「真的打断了挂起中的连接动作」和「取消只是
/// 一个要等下一个检查点才生效的标志位」区分开。
async test "cancel interrupts a request waiting for the response headers" {
  @async.with_task_group() <| group => {
    let port = slow_headers_server(group)
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let (error, elapsed) = request_then_cancel(
      group,
      client,
      @moonhttp.Config::new("http://127.0.0.1:\{port}/slow").with_cancel_token(
        token,
      ),
      token,
      50,
      "用户点了停止",
    )
    assert_true(error.is_cancelled())
    assert_eq(error.message(), "用户点了停止")
    // 对面 3 秒才回响应头，这里远早于它结束
    assert_true(elapsed < 1000)
    // 响应头都没到手，错误里没有响应
    assert_true(error.response() is None)
  }
}

///|
/// 请求挂在「读响应体」上时取消：同样是立刻结束，并且**失败现场还在**——
/// 错误里带着已经收到的状态行、响应头与那半截正文，与超时、断连的口径一致。
async test "cancel during the body read keeps the bytes already received" {
  @async.with_task_group() <| group => {
    let port = partial_then_stall_server(group)
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let (error, elapsed) = request_then_cancel(
      group,
      client,
      @moonhttp.Config::new("http://127.0.0.1:\{port}/partial").with_cancel_token(
        token,
      ),
      token,
      50,
      "不下了",
    )
    assert_true(error.is_cancelled())
    assert_eq(error.message(), "不下了")
    assert_true(elapsed < 1000)
    let received = error.response().unwrap()
    assert_eq(received.status, 200)
    assert_eq(received.text(), "partial-body")
  }
}

///|
/// 取消同时配了 `timeout` 时，先到的那个说了算：这里取消在 50ms、超时在 3s，
/// 报的必须是取消而不是 `ECONNABORTED`。
///
/// 它钉住的是取消作用域在超时之外——取消不能被超时那层的错误收敛吞掉。
async test "cancel reports cancelled rather than a timeout when it lands first" {
  @async.with_task_group() <| group => {
    let port = slow_headers_server(group)
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let (error, _elapsed) = request_then_cancel(
      group,
      client,
      @moonhttp.Config::new("http://127.0.0.1:\{port}/slow")
      .with_timeout(3000)
      .with_cancel_token(token),
      token,
      50,
      "取消优先",
    )
    assert_true(error.is_cancelled())
    assert_true(error.code() is @moonhttp.ErrorCode::Cancelled)
  }
}

///|
/// 被取消的是库自己 spawn 的子任务，不是调用方的协程：取消之后同一条协程
/// 接着发下一个请求，必须正常成功（取消不该把调用方「粘」在取消状态里）。
async test "a cancelled request does not stick to the calling coroutine" {
  @async.with_task_group() <| group => {
    let slow_port = slow_headers_server(group)
    let ok_port = ok_server(group)
    let client = @moonhttp.Client::new()
    let token = @moonhttp.CancelToken::new()
    let (error, _elapsed) = request_then_cancel(
      group,
      client,
      @moonhttp.Config::new("http://127.0.0.1:\{slow_port}/slow").with_cancel_token(
        token,
      ),
      token,
      50,
      "第一次取消",
    )
    assert_true(error.is_cancelled())
    // 同一条协程、同一个 Client，换一个 token 再发一次
    let response = client.request(
      @moonhttp.Config::new("http://127.0.0.1:\{ok_port}/ok").with_cancel_token(
        @moonhttp.CancelToken::new(),
      ),
    )
    assert_eq(response.status, 200)
    assert_eq(response.text(), "ok")
  }
}

///|
/// 取消落在重定向链的某一跳上：第一跳 302 立刻回来，第二跳挂住，取消在第二跳
/// 等待期间生效——错误里没有响应（这一跳的响应头还没到手），但错误码是取消。
async test "cancel interrupts a redirect chain on a later hop" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((request, _body, conn) => {
        if request.path == "/first" {
          let headers : Map[@http.CaseInsensitiveString, String] = Map([])
          headers[@http.CaseInsensitiveString("Location")] = "/second"
          conn..send_response(302, "Found", extra_headers=headers).flush()
          conn..write_string("moved").end_response()
        } else {
          @async.sleep(3000)
          conn..send_response(200, "OK").flush()
          conn..write_string("late").end_response()
        }
      })
    }
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let (error, elapsed) = request_then_cancel(
      group,
      client,
      @moonhttp.Config::new("http://127.0.0.1:\{port}/first").with_cancel_token(
        token,
      ),
      token,
      50,
      "链上取消",
    )
    assert_true(error.is_cancelled())
    assert_eq(error.message(), "链上取消")
    assert_true(elapsed < 1000)
  }
}

///|
/// 顺带说明「取消之后重试」为什么安全：重试配方就是拿 `error.config()` 再调一次
/// `Client::request`，而那次调用会走取消预检查——配置里带着同一个 token，
/// 所以已经取消的 token 让重试**立刻失败、不产生第二次请求**，
/// 不会把处理器里的无脑重试变成一串真实 I/O。
///
/// 注意这次取消是重试那一步（响应侧处理器内部）自己撞上预检查的结果，它直接
/// 抛给了调用方；管线里发生的取消则走**请求侧**错误处理器（取消是请求阶段的
/// 失败，见 `src/interceptor_test.mbt` 的 "cancellation goes to the request
/// error handler"）。挡重复投递的一直是预检查，不是错误处理器里的特判。
async test "a retry after cancel fails fast without another request" {
  let mock = @transport.MockTransport::new(
    raw_response(500, "InternalServerError", "boom"),
  )
  let transport : &@transport.Transport = mock
  let plain = @moonhttp.Client::new(transport~)
  let token = @moonhttp.CancelToken::new()
  let interceptors = @moonhttp.Interceptors::new().use_response(
    response => response,
    on_rejected=error => {
      // 无脑重试：先把 token 取消（模拟用户在这中间点了停止），再照原样重发
      token.cancel(message="取消之后重试")
      plain.request(error.config())
    },
  )
  let client = @moonhttp.Client::new(transport~, interceptors~)
  let error = try {
    ignore(
      client.request(@moonhttp.Config::new("/flaky").with_cancel_token(token)),
    )
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_true(error.is_cancelled())
  assert_eq(error.message(), "取消之后重试")
  // 只有第一次真的发出去了：重试被预检查挡在传输层之前
  assert_eq(mock.request_count(), 1)
}
