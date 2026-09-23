// 流式入口（`Client::stream`）的用例：不读响应体就把状态行与响应头交出去，
// 由调用方决定怎么读。全部用 Mock 传输层，不联网。

///|
/// 造一份 SSE 风格的原始响应：事件之间用空行分隔。
fn sse_response(body : String) -> @transport.RawResponse {
  {
    status: 200,
    status_text: "OK",
    headers: @transport.Headers::new().set("Content-Type", "text/event-stream"),
    body: @transport.ResponseBody::from_bytes(@utf8.encode(body)),
  }
}

///|
/// 拿到流式响应时状态码与响应头已经可用——SSE 靠的就是这一步：
/// 先看状态码与 `Content-Type`，再决定怎么读。
async test "stream exposes status and headers before reading the body" {
  let (client, _) = client_with(sse_response("data: one\n\ndata: two\n\n"))
  let response = client.stream(
    @moonhttp.Config::new("https://example.com/events"),
  )
  assert_eq(response.status, 200)
  assert_eq(response.status_text, "OK")
  assert_eq(response.headers.get("content-type"), Some("text/event-stream"))
  assert_true(response.is_success())
  // 事件按空行切分，一次一个；分隔符本身不返回
  assert_eq(response.read_until("\n\n"), Some("data: one"))
  assert_eq(response.read_until("\n\n"), Some("data: two"))
  assert_eq(response.read_until("\n\n"), None)
}

///|
/// 流式入口走的是与 `request` 同一套 prepare：合并实例默认值、拼 base_url、
/// 追加 query、拍平三层头。这里断言真的发出去的请求，而不是只看响应。
async test "stream builds the request like request does" {
  let (client, mock) = client_with(sse_response("data: x\n\n"))
  let api = client.create(
    @moonhttp.Config::default()
    .with_base_url("https://api.example.com")
    .with_common_header("Accept", "text/event-stream"),
  )
  let response = api.stream(
    @moonhttp.Config::new("/events").with_params({ "room": 7 }),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(sent.url, "https://api.example.com/events?room=7")
  assert_eq(sent.headers.get("Accept"), Some("text/event-stream"))
  assert_eq(sent.http_method, @moonhttp.Method::Get)
  response.close()
}

///|
/// 下载场景：先拿流看状态码与响应头，再一次性把内容读完。
/// 读完即结束，`close` 幂等。
async test "stream reads the whole body on demand" {
  let (client, _) = client_with(sse_response("hello"))
  let response = client.stream(
    @moonhttp.Config::new("https://example.com/file"),
  )
  // read_some 可以限长，用于边读边处理（下载进度就是在这上面累加）
  assert_eq(response.read_some(max_len=2), Some(b"he"))
  assert_eq(response.read_all(), b"llo")
  assert_eq(response.read_some(), None)
  response.close()
}

///|
/// 状态码不被放行时：先把错误体读完，再按状态码报错，错误里带着响应。
/// 长连场景下这是唯一能立刻看到「为什么没连上」的地方。
async test "stream raises with the error body when status is rejected" {
  let (client, _) = client_with(
    raw_response(500, "Internal Server Error", "{\"msg\": \"boom\"}"),
  )
  let error = try {
    ignore(client.stream(@moonhttp.Config::new("https://example.com/events")))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@moonhttp.HttpError(_)))
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::BadResponse)
  let failed = error.response().unwrap()
  assert_eq(failed.status, 500)
  // 错误体不做 JSON 解析（格式不可预期），原文与原始字节都挂在响应上
  assert_eq(failed.text(), "{\"msg\": \"boom\"}")
}

///|
/// 自定义 `validate_status` 放行 4xx 时，与 `request` 一样把响应交出来，
/// 由调用方自己按状态码判断。
async test "stream honors custom validate_status" {
  let (client, _) = client_with(raw_response(404, "Not Found", "nope"))
  let response = client.stream(
    @moonhttp.Config::new("https://example.com/missing").with_validate_status(status => {
      status < 500
    }),
  )
  assert_eq(response.status, 404)
  assert_true(!response.is_success())
  assert_eq(response.read_all(), b"nope")
}
