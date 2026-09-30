// cookie 自动维护的端到端用例：jar 挂在 `Client` 上之后，
// 携带 / 存取 / 过期 / 跨域重定向 / 派生实例共享，全部走 Mock 传输层验证。
// jar 本体的解析与匹配规则在 `src/cookie/`（同步单测），这里只钉「接线」。

///|
/// 造一份可带 Set-Cookie（多值）与可选 `Location` 的响应；
/// 带 `Location` 时是 302，否则 200。
fn cookie_response(
  set_cookies : Array[String],
  location? : String,
) -> @transport.RawResponse {
  let headers = match location {
    Some(target) => @transport.Headers::new().set("Location", target)
    None => @transport.Headers::new()
  }
  {
    status: if location is Some(_) {
      302
    } else {
      200
    },
    status_text: if location is Some(_) {
      "Found"
    } else {
      "OK"
    },
    headers,
    set_cookies,
    body: @transport.ResponseBody::from_bytes(b"{}"),
  }
}

///|
/// 造一个带 cookie 罐的实例，把罐与 Mock 一起返回。
fn cookie_client_with(
  responses : Array[@transport.RawResponse],
) -> (@moonhttp.Client, @transport.MockTransport, @moonhttp.CookieJar) {
  let jar = @moonhttp.CookieJar::new()
  let mock = @transport.MockTransport::from_responses(responses)
  let transport : &@transport.Transport = mock
  (@moonhttp.Client::new(transport~, cookie_jar=jar), mock, jar)
}

///|
/// 取第 `index` 次请求实际发出的 `Cookie` 头（没发过是 `None`）。
fn sent_cookie(mock : @transport.MockTransport, index : Int) -> String? {
  mock.received()[index].headers.get("Cookie")
}

///|
/// 响应的 Set-Cookie 入罐，下一次请求自动带上。
async test "set-cookie is stored and carried on the next request" {
  let (client, mock, _) = cookie_client_with([
    cookie_response(["session=abc; Path=/; Max-Age=3600"]),
    cookie_response([]),
  ])
  let _ = client.request(@moonhttp.Config::new("https://example.com/login"))
  assert_eq(sent_cookie(mock, 0), None)
  let _ = client.request(@moonhttp.Config::new("https://example.com/profile"))
  assert_eq(sent_cookie(mock, 1), Some("session=abc"))
}

///|
/// 用户显式设置的 `Cookie` 头优先于 jar 的自动注入（`set_if_absent` 口径）。
async test "explicit cookie header wins over the jar" {
  let (client, mock, _) = cookie_client_with([
    cookie_response(["auto=1; Path=/"]),
    cookie_response([]),
  ])
  let _ = client.request(@moonhttp.Config::new("https://example.com/first"))
  let _ = client.request(
    @moonhttp.Config::new("https://example.com/second").with_header(
      "Cookie", "manual=1",
    ),
  )
  assert_eq(sent_cookie(mock, 1), Some("manual=1"))
}

///|
/// 不传 jar 就不做任何 cookie 维护：响应里的 Set-Cookie 不入罐（无处可入），
/// 请求也永远不会自动带 `Cookie` 头——行为与从前完全一致。
async test "no jar means no cookie maintenance" {
  let mock = @transport.MockTransport::from_responses([
    cookie_response(["a=1; Path=/"]),
    cookie_response([]),
  ])
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let _ = client.request(@moonhttp.Config::new("https://example.com/first"))
  let _ = client.request(@moonhttp.Config::new("https://example.com/second"))
  assert_eq(sent_cookie(mock, 1), None)
}

///|
/// 跨域重定向不泄露 cookie：a.com 种下的会话 cookie 不跟着跳到 other.com；
/// 各域的 cookie 在后续对该域的请求里各归各位。
async test "cross-host redirect does not leak cookies" {
  let (client, mock, _) = cookie_client_with([
    // 第一跳：a.com 302 去 other.com，顺手种 a.com 的 cookie
    cookie_response(["a=1; Path=/"], location="https://other.com/next"),
    // 第二跳：other.com 200，种 other.com 的 cookie
    cookie_response(["o=2; Path=/"]),
    // 两次后续请求
    cookie_response([]),
    cookie_response([]),
  ])
  let _ = client.request(@moonhttp.Config::new("https://a.com/start"))
  // 第一跳发出时罐子是空的；第二跳到了别的域，a.com 的 cookie 不能跟过去
  assert_eq(sent_cookie(mock, 0), None)
  assert_eq(sent_cookie(mock, 1), None)
  // 各域后续请求：cookie 只回各自的域
  let _ = client.request(@moonhttp.Config::new("https://other.com/anywhere"))
  assert_eq(sent_cookie(mock, 2), Some("o=2"))
  let _ = client.request(@moonhttp.Config::new("https://a.com/again"))
  assert_eq(sent_cookie(mock, 3), Some("a=1"))
}

///|
/// 同域重定向照常携带：跳转链中种下的 cookie，下一跳就能用上（登录流的形态）。
async test "same-host redirect carries cookies along the chain" {
  let (client, mock, _) = cookie_client_with([
    cookie_response(["ticket=t-1; Path=/"], location="https://a.com/finish"),
    cookie_response([]),
  ])
  let _ = client.request(@moonhttp.Config::new("https://a.com/login"))
  assert_eq(sent_cookie(mock, 1), Some("ticket=t-1"))
}

///|
/// 一份响应里的多条 Set-Cookie 各自入罐；过期的那条（过去的 Expires）不发送。
async test "multiple set-cookies are stored and expired ones dropped" {
  let (client, mock, _) = cookie_client_with([
    cookie_response([
      "live=1; Path=/", "dead=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT",
    ]),
    cookie_response([]),
  ])
  let _ = client.request(@moonhttp.Config::new("https://example.com/first"))
  let _ = client.request(@moonhttp.Config::new("https://example.com/second"))
  assert_eq(sent_cookie(mock, 1), Some("live=1"))
}

///|
/// `Max-Age=0` 是删除信号：同名 cookie 在后续请求里消失。
async test "max-age zero deletes the cookie" {
  let (client, mock, _) = cookie_client_with([
    cookie_response(["gone=1; Path=/; Max-Age=3600"]),
    cookie_response(["gone=1; Path=/; Max-Age=0"]),
    cookie_response([]),
  ])
  let _ = client.request(@moonhttp.Config::new("https://example.com/first"))
  let _ = client.request(@moonhttp.Config::new("https://example.com/second"))
  let _ = client.request(@moonhttp.Config::new("https://example.com/third"))
  assert_eq(sent_cookie(mock, 1), Some("gone=1"))
  assert_eq(sent_cookie(mock, 2), None)
}

///|
/// 流式入口（`stream`）走同一条重定向循环，cookie 的注入与捕获同样生效。
async test "stream entry maintains cookies too" {
  let (client, mock, _) = cookie_client_with([
    cookie_response(["s=1; Path=/"]),
    cookie_response([]),
  ])
  let stream = client.stream(@moonhttp.Config::new("https://example.com/file"))
  stream.close()
  let _ = client.request(@moonhttp.Config::new("https://example.com/after"))
  assert_eq(sent_cookie(mock, 1), Some("s=1"))
}

///|
/// `create` 派生的实例与父实例共享同一个 jar：换个默认值不丢会话状态。
async test "derived client shares the jar with its parent" {
  let (client, mock, _) = cookie_client_with([
    cookie_response(["shared=1; Path=/"]),
    cookie_response([]),
    cookie_response([]),
  ])
  let _ = client.request(@moonhttp.Config::new("https://example.com/login"))
  let derived = client.create(@moonhttp.Config::default().with_timeout(5000))
  let _ = derived.request(
    @moonhttp.Config::new("https://example.com/via-child"),
  )
  assert_eq(sent_cookie(mock, 1), Some("shared=1"))
  // 父实例也看得到同一份会话状态
  let _ = client.request(
    @moonhttp.Config::new("https://example.com/via-parent"),
  )
  assert_eq(sent_cookie(mock, 2), Some("shared=1"))
}
