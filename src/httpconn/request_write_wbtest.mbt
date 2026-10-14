// build_request_headers 的自动头契约（包私有函数，白盒直测）：
// 用户没设 `User-Agent` 时补 `DEFAULT_USER_AGENT`，显式设置的同名头
// 永远赢（与 Host / Accept-Encoding 同一条 set_if_absent 口径）。

///|
fn bare_request(headers : @transport.Headers) -> @transport.PreparedRequest {
  {
    http_method: @transport.Method::Get,
    url: "http://127.0.0.1:1/",
    headers,
    body: None,
    timeout: None,
    proxy: None,
    on_upload_progress: None,
    signal: None,
  }
}

///|
test "default User-Agent is injected when user did not set one" {
  let request = bare_request(@transport.Headers::new())
  let headers = build_request_headers(request, parse_target(request.url), false)
  assert_eq(headers.get_last("User-Agent"), Some("moonhttp/0.4.0"))
}

///|
test "explicit User-Agent wins over the default" {
  let request = bare_request(
    @transport.Headers::new().set("User-Agent", "my-app/1.0"),
  )
  let headers = build_request_headers(request, parse_target(request.url), false)
  assert_eq(headers.get_last("User-Agent"), Some("my-app/1.0"))
}

///|
/// Connection 头的开关契约（docs/21）：池禁用（declare_close = true）时
/// 补 `Connection: close`（phase 1 口径）；池启用时不发——HTTP/1.1 的
/// 持久连接是默认，对齐 Go / Python / Node。用户显式设置永远赢。
test "Connection header follows the pool switch, explicit wins" {
  let plain = bare_request(@transport.Headers::new())
  let pooled = build_request_headers(plain, parse_target(plain.url), false)
  assert_eq(pooled.get_last("Connection"), None)
  let unpooled = build_request_headers(plain, parse_target(plain.url), true)
  assert_eq(unpooled.get_last("Connection"), Some("close"))
  let user_set = bare_request(
    @transport.Headers::new().set("Connection", "keep-alive"),
  )
  let kept = build_request_headers(user_set, parse_target(user_set.url), true)
  assert_eq(kept.get_last("Connection"), Some("keep-alive"))
}
