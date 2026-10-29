// SSE 自动重连的端到端用例（Mock / 脚本化传输层）。
//
// 解析规则在 src/sse/sse_test.mbt，入口与基本读取在 sse_stream_test.mbt；
// 这里只测「开启策略之后」的行为：重订阅、Last-Event-ID、retry 间隔、
// 次数用尽、不可重试错误与取消。
//
// 与 sse_stream_test.mbt 分开也是为了守 RL-04 的文件行数上限。

///|
/// 脚本化传输层的一步：返回响应或抛出传输层错误。
priv enum ScriptedStep {
  Reply(@transport.RawResponse)
  Raise(@transport.TransportError)
}

///|
/// 按脚本逐个返回，并记录收到的请求。
/// `MockTransport` 只能整组成功或整组失败，测不了「第一次成功、第二次超时」。
priv struct ScriptedTransport {
  steps : Array[ScriptedStep]
  received : Array[@transport.PreparedRequest]
}

///|
fn ScriptedTransport::new(steps : Array[ScriptedStep]) -> ScriptedTransport {
  { steps, received: [], }
}

///|
impl @transport.Transport for ScriptedTransport with fn send(
  self : ScriptedTransport,
  request : @transport.PreparedRequest,
) {
  self.received.push(request)
  let index = self.received.length() - 1
  match self.steps[index] {
    Reply(response) => response
    Raise(error) => raise error
  }
}

///|
fn reconnect_config(max_retries : Int32, delay : Int32) -> @moonhttp.Config {
  @moonhttp.Config::new("https://example.com/events").with_sse_reconnect(
    @moonhttp.SseReconnect::new()
    .with_max_retries(max_retries)
    .with_default_delay(delay),
  )
}

///|
async test "sse reconnects after eof and sends last-event-id" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("id: 42\ndata: a\n\n"),
    sse_response("data: b\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(1, 1))

  assert_eq(events.next_event().unwrap().data, "a")
  assert_eq(events.next_event().unwrap().data, "b")
  assert_eq(mock.request_count(), 2)
  assert_eq(mock.received()[1].headers.get("Last-Event-ID"), Some("42"))
}

///|
async test "an id-only block still seeds last-event-id" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("id: 7\n\n"),
    sse_response("data: b\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(1, 1))

  // 第一块没有事件，读到 EOF 后直接重连；第二次请求必须带上那个 id。
  assert_eq(events.next_event().unwrap().data, "b")
  assert_eq(mock.request_count(), 2)
  assert_eq(mock.received()[1].headers.get("Last-Event-ID"), Some("7"))
}

///|
async test "an empty id clears last-event-id on reconnect" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("id: 42\ndata: a\n\nid:\n\n"),
    sse_response("data: b\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(1, 1))

  assert_eq(events.next_event().unwrap().data, "a")
  assert_eq(events.next_event().unwrap().data, "b")
  // 服务端用空的 id: 把 last event ID 清掉了，重连不再带这个头。
  assert_false(mock.received()[1].headers.has("Last-Event-ID"))
}

///|
async test "the stream retry interval overrides the policy default" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("retry: 0\ndata: a\n\n"),
    sse_response("data: b\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  // 策略默认 5 秒；流里的 retry: 0 必须覆盖它，否则这条用例会超时。
  let events = client.sse(reconnect_config(1, 5000))

  assert_eq(events.next_event().unwrap().data, "a")
  let started = @async.now()
  assert_eq(events.next_event().unwrap().data, "b")
  assert_true((@async.now() - started).to_int() < 1000)
}

///|
async test "a clean eof stops after the configured number of attempts" {
  let mock = @transport.MockTransport::from_responses([sse_response("")])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(2, 1))

  // 空流只会干净 EOF：重连两次后放弃，返回 None（不是错误）。
  assert_eq(events.next_event(), None)
  assert_eq(mock.request_count(), 3)
}

///|
async test "a reconnect response that is not an event stream stops the retry" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("data: a\n\n"),
    raw_response(200, "OK", "{}"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(3, 1))

  assert_eq(events.next_event().unwrap().data, "a")
  let error = try {
    ignore(events.next_event())
    None
  } catch {
    error => Some(error)
  }
  assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::NotSupported)
  assert_eq(mock.request_count(), 2)
}

///|
async test "a 5xx during reconnect is retried" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("data: a\n\n"),
    raw_response(503, "Service Unavailable", "busy"),
    sse_response("data: b\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(3, 1))

  assert_eq(events.next_event().unwrap().data, "a")
  assert_eq(events.next_event().unwrap().data, "b")
  assert_eq(mock.request_count(), 3)
}

///|
async test "a 4xx during reconnect is not retried" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("data: a\n\n"),
    raw_response(401, "Unauthorized", "no"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(3, 1))

  assert_eq(events.next_event().unwrap().data, "a")
  let error = try {
    ignore(events.next_event())
    None
  } catch {
    error => Some(error)
  }
  assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::BadRequest)
  assert_eq(mock.request_count(), 2)
}

///|
async test "a retryable reconnect failure is retried" {
  let transport = ScriptedTransport::new([
    Reply(sse_response("data: a\n\n")),
    Raise(@transport.TransportError::Timeout),
    Reply(sse_response("data: b\n\n")),
  ])
  let transport_ref : &@transport.Transport = transport
  let client = @moonhttp.Client::new(transport=transport_ref)
  let events = client.sse(reconnect_config(3, 1))

  assert_eq(events.next_event().unwrap().data, "a")
  assert_eq(events.next_event().unwrap().data, "b")
  assert_eq(transport.received.length(), 3)
}

///|
async test "cancelling during the reconnect wait stops immediately" {
  let controller = @moonhttp.AbortController::new()
  let mock = @transport.MockTransport::from_responses([
    sse_response("data: a\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(3, 2000), signal=controller.signal())

  assert_eq(events.next_event().unwrap().data, "a")
  let started = @async.now()
  let error = @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      @async.sleep(50)
      controller.abort()
    }
    try {
      ignore(events.next_event())
      None
    } catch {
      error => Some(error)
    }
  }
  assert_true((@async.now() - started).to_int() < 1000)
  assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::Cancelled)
}

///|
async test "close stops the reconnect loop" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("data: a\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(reconnect_config(3, 1))

  assert_eq(events.next_event().unwrap().data, "a")
  events.close()
  assert_eq(events.next_event(), None)
  assert_eq(mock.request_count(), 1)
}

///|
async test "sse without a reconnect policy keeps the old eof behavior" {
  let mock = @transport.MockTransport::from_responses([
    sse_response("data: a\n\n"),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let events = client.sse(@moonhttp.Config::new("https://example.com/events"))

  assert_eq(events.next_event().unwrap().data, "a")
  assert_eq(events.next_event(), None)
  assert_eq(mock.request_count(), 1)
}
