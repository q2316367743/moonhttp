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
  let headers = build_request_headers(request, parse_target(request.url))
  assert_eq(headers.get_last("User-Agent"), Some("moonhttp/0.4.0"))
}

///|
test "explicit User-Agent wins over the default" {
  let request = bare_request(
    @transport.Headers::new().set("User-Agent", "my-app/1.0"),
  )
  let headers = build_request_headers(request, parse_target(request.url))
  assert_eq(headers.get_last("User-Agent"), Some("my-app/1.0"))
}
