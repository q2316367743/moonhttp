///|
/// 构造一份最小可用的原始响应，测试里复用。
fn ok_response(body : Bytes) -> @transport.RawResponse {
  {
    status: 200,
    status_text: "OK",
    headers: @transport.Headers::new().set("Content-Type", "text/plain"),
    body,
  }
}

///|
/// Mock 传输层要记录请求、按队列返回响应；队列耗尽后复用最后一个响应。
async test "mock transport records requests and serves queued responses" {
  let mock = @transport.MockTransport::from_responses([
    ok_response(b"first"),
    ok_response(b"second"),
  ])
  let transport : &@transport.Transport = mock
  let request = @transport.PreparedRequest::{
    http_method: @transport.Method::Get,
    url: "https://example.com/a",
    headers: @transport.Headers::new(),
    body: None,
    timeout: None,
  }
  let first = transport.send(request)
  assert_eq(first.body, b"first")
  let second = transport.send(request)
  assert_eq(second.body, b"second")
  // 队列耗尽后继续复用最后一个响应
  let third = transport.send(request)
  assert_eq(third.body, b"second")
  assert_eq(mock.request_count(), 3)
  assert_eq(mock.last_request().unwrap().url, "https://example.com/a")
}

///|
/// 没配置响应时抛出 `Unsupported`，而不是返回一个空响应当作成功——
/// 静默的成功会让测试变得不可信。
async test "mock transport without responses fails loudly" {
  let mock = @transport.MockTransport::from_responses([])
  let transport : &@transport.Transport = mock
  let request = @transport.PreparedRequest::{
    http_method: @transport.Method::Get,
    url: "https://example.com",
    headers: @transport.Headers::new(),
    body: None,
    timeout: None,
  }
  let error = try {
    ignore(transport.send(request))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@transport.TransportError::Unsupported(_)))
}

///|
/// 失败路径：Mock 预置的错误要原样传给调用方，
/// 上层才能据此映射成 `ErrorCode::Timeout` / `ErrorCode::Network`。
async test "mock transport propagates configured failure" {
  let mock = @transport.MockTransport::failing(
    @transport.TransportError::Timeout,
  )
  let transport : &@transport.Transport = mock
  let request = @transport.PreparedRequest::{
    http_method: @transport.Method::Post,
    url: "https://example.com",
    headers: @transport.Headers::new(),
    body: Some(b"payload"),
    timeout: Some(1000),
  }
  let error = try {
    ignore(transport.send(request))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@transport.TransportError::Timeout))
  // 即使失败，请求也要被记录下来，便于定位是哪个请求出的问题
  assert_eq(mock.request_count(), 1)
}

///|
/// 真实传输层对「协议不支持」的分类。
/// 这个用例不需要网络：地址在校验阶段就会被拒绝。
async test "async transport classifies unsupported protocols" {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let request = @transport.PreparedRequest::{
    http_method: @transport.Method::Get,
    url: "ftp://example.com/file",
    headers: @transport.Headers::new(),
    body: None,
    timeout: Some(1000),
  }
  let error = try {
    ignore(transport.send(request))
    None
  } catch {
    error => Some(error)
  }
  // 具体分类由底层决定，这里只要求它被收敛成传输层错误而不是裸的底层错误
  assert_true(
    error
    is Some(
      @transport.TransportError::Network(_)
      | @transport.TransportError::Unsupported(_)
      | @transport.TransportError::Timeout
    ),
  )
}

///|
/// 真实传输层对「连不上」的分类：本机一个必然无人监听的端口。
/// 这验证的是错误映射本身，不依赖外网。
async test "async transport classifies connection failures" {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let request = @transport.PreparedRequest::{
    http_method: @transport.Method::Get,
    url: "http://127.0.0.1:1/",
    headers: @transport.Headers::new(),
    body: None,
    // 给一个上限，避免万一卡在重试上导致测试挂住
    timeout: Some(3000),
  }
  let error = try {
    ignore(transport.send(request))
    None
  } catch {
    error => Some(error)
  }
  assert_true(
    error
    is Some(
      @transport.TransportError::Network(_)
      | @transport.TransportError::Timeout
    ),
  )
}

///|
/// Mock 的请求记录访问器：一次都没发过时 last_request 为 None。
async test "mock transport accessors" {
  let mock = @transport.MockTransport::new(ok_response(b"x"))
  assert_eq(mock.request_count(), 0)
  assert_eq(mock.received().length(), 0)
  assert_true(mock.last_request() is None)
  let transport : &@transport.Transport = mock
  ignore(
    transport.send(@transport.PreparedRequest::{
      http_method: @transport.Method::Get,
      url: "https://example.com",
      headers: @transport.Headers::new(),
      body: None,
      timeout: None,
    }),
  )
  assert_eq(mock.received().length(), 1)
  assert_true(mock.last_request() is Some(_))
}
