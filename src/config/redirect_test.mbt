// `Config::next_redirect` 的规则测试：跟随判定、方法 / body / 头的改写、
// 凭据的存留。全部是纯逻辑，不需要传输层。

///|
/// 取出下一跳。断言里用 `Option[Config]`（Config 含函数字段，没有 `Eq`），
/// 真在用例里 panic 说明「本来期望跟随」这个前提不成立。
fn next_hop(result : @config.Config?) -> @config.Config {
  result.unwrap()
}

///|
/// 观察凭据存留的窗口：显式设一个 `Authorization` 头，看它有没有活过这一跳。
fn credential_kept(from_url : String, to_url : String) -> Bool {
  let config = @config.Config::new(from_url).with_header(
    "Authorization", "Bearer token",
  )
  let next = next_hop(config.next_redirect(from_url, 302, Some(to_url)))
  next.headers.unwrap().has("Authorization")
}

///|
/// 只有「3xx + 有非空白 Location」才跟随：其余情况响应原样交出去，
/// 由 `validate_status` 判定成败。
test "next_redirect only follows 3xx with a usable location" {
  let config = @config.Config::new("https://api.example.com/users")
  assert_true(
    config.next_redirect("https://api.example.com/users", 200, Some("/v2"))
    is None,
  )
  assert_true(
    config.next_redirect("https://api.example.com/users", 404, Some("/v2"))
    is None,
  )
  // 3xx 但没有 Location
  assert_true(
    config.next_redirect("https://api.example.com/users", 302, None) is None,
  )
  // Location 是空串或空白：与 follow-redirects 的 `!location` 一致
  assert_true(
    config.next_redirect("https://api.example.com/users", 302, Some("")) is None,
  )
  assert_true(
    config.next_redirect("https://api.example.com/users", 302, Some("   "))
    is None,
  )
}

///|
/// 301/302 上的 POST 降级成 GET，请求体与 `content-*` 一起丢掉；
/// 其余请求级头照旧带过去。
test "301 and 302 turn POST into GET and drop the entity" {
  for status in [301, 302] {
    let config = @config.Config::new("https://api.example.com/users")
      .with_method(@config.Method::Post)
      .with_data_from_json({ "name": "moon" })
      .with_header("Content-Type", "application/json")
      .with_header("X-Trace", "1")
    let next = next_hop(
      config.next_redirect(
        "https://api.example.com/users",
        status,
        Some("/created"),
      ),
    )
    assert_eq(next.http_method, Some(@config.Method::Get))
    assert_eq(next.url, Some("https://api.example.com/created"))
    assert_eq(next.serialize_body().bytes, None)
    assert_eq(next.serialize_body().content_type, None)
    assert_eq(next.headers.unwrap().has("Content-Type"), false)
    assert_eq(next.headers.unwrap().get("X-Trace"), Some("1"))
  }
}

///|
/// 301/302 上的非 POST（PUT / PATCH…）保持方法与实体——这是 follow-redirects
/// 的真实行为，RFC 只规定「可以」把 POST 降级，没有要求降级别的。
test "301 and 302 keep non POST methods and their entity" {
  let config = @config.Config::new("https://api.example.com/users/1")
    .with_method(@config.Method::Put)
    .with_data_from_str("raw")
    .with_header("Content-Type", "text/plain")
  let next = next_hop(
    config.next_redirect(
      "https://api.example.com/users/1",
      302,
      Some("/users/2"),
    ),
  )
  assert_eq(next.http_method, Some(@config.Method::Put))
  assert_eq(next.serialize_body().bytes, Some(b"raw"))
  assert_eq(next.headers.unwrap().get("Content-Type"), Some("text/plain"))
}

///|
/// 303 的语义是「去 GET 那个资源」，所以除 GET / HEAD 之外一律改成 GET 并丢掉实体。
test "303 rewrites everything except GET and HEAD" {
  let put = @config.Config::new("https://api.example.com/users")
    .with_method(@config.Method::Put)
    .with_data_from_str("raw")
  let next = next_hop(
    put.next_redirect("https://api.example.com/users", 303, Some("/done")),
  )
  assert_eq(next.http_method, Some(@config.Method::Get))
  assert_eq(next.serialize_body().bytes, None)

  let head = @config.Config::new("https://api.example.com/users").with_method(
    @config.Method::Head,
  )
  let next = next_hop(
    head.next_redirect("https://api.example.com/users", 303, Some("/done")),
  )
  assert_eq(next.http_method, Some(@config.Method::Head))
}

///|
/// 307/308 的存在意义就是「原样重发」：方法、实体与 `Content-Type` 全保留。
test "307 and 308 resend the method and entity" {
  for status in [307, 308] {
    let config = @config.Config::new("https://api.example.com/users")
      .with_method(@config.Method::Post)
      .with_data_from_json({ "name": "moon" })
    let next = next_hop(
      config.next_redirect(
        "https://api.example.com/users",
        status,
        Some("/other"),
      ),
    )
    assert_eq(next.http_method, Some(@config.Method::Post))
    assert_eq(next.serialize_body().bytes, Some(b"{\"name\":\"moon\"}"))
    assert_eq(next.serialize_body().content_type, Some("application/json"))
  }
}

///|
/// 下一跳的地址是相对 `Location` 相对**实际发出去的地址**解析出来的；
/// `base_url` 与 `params` 必须清空，否则会被二次拼接 / 二次追加。
test "next hop clears base_url and params" {
  let config = @config.Config::new("/users")
    .with_base_url("https://api.example.com/api")
    .with_params({ "page": 1 })
  let current = "https://api.example.com/api/users?page=1"
  let next = next_hop(
    config.next_redirect(current, 302, Some("../v2/users#top")),
  )
  assert_eq(next.url, Some("https://api.example.com/v2/users"))
  assert_eq(next.base_url, None)
  assert_eq(next.params, None)
}

///|
/// 同 host 的重定向保留凭据：`auth` 字段与显式设的凭据头都留着。
test "credentials survive a same host redirect" {
  let config = @config.Config::new("https://api.example.com/users")
    .with_auth("alice", "s3cret")
    .with_header("Cookie", "session=1")
  let next = next_hop(
    config.next_redirect("https://api.example.com/users", 302, Some("/v2")),
  )
  assert_true(next.auth is Some(_))
  assert_eq(next.headers.unwrap().get("Cookie"), Some("session=1"))
}

///|
/// 换 host 时凭据要丢干净：三层头都扫，`auth` 字段也清掉
/// （否则 `build_prepared_request` 会照着它把 `Authorization` 补回来）。
test "credentials are dropped across hosts" {
  let config = @config.Config::new("https://api.example.com/users")
    .with_auth("alice", "s3cret")
    .with_header("Authorization", "Bearer token")
    .with_header("Cookie", "session=1")
    .with_common_header("Proxy-Authorization", "Basic cHJveHk=")
    .with_method_header(@config.Method::Get, "Cookie", "method=1")
  let next = next_hop(
    config.next_redirect(
      "https://api.example.com/users",
      302,
      Some("https://other.example.org/users"),
    ),
  )
  assert_eq(next.auth, None)
  assert_eq(next.headers.unwrap().has("Authorization"), false)
  assert_eq(next.headers.unwrap().has("Cookie"), false)
  assert_eq(next.common_headers.unwrap().has("Proxy-Authorization"), false)
  assert_eq(
    next.method_headers.unwrap().get(@config.Method::Get).unwrap().has("Cookie"),
    false,
  )
}

///|
/// 两种「看起来还行」的跨地址情况保留凭据：跳到自己的子域、同 host 的
/// http→https 升级；显式写了默认端口也算同一个 host。
test "subdomains and https upgrades keep credentials" {
  assert_true(
    credential_kept(
      "https://api.example.com/u", "https://cdn.api.example.com/u",
    ),
  )
  assert_true(
    credential_kept("http://api.example.com/u", "https://api.example.com/u"),
  )
  assert_true(
    credential_kept(
      "https://api.example.com/u", "https://api.example.com:443/u",
    ),
  )
}

///|
/// 协议降级、换域、改端口都要丢凭据；`example.com.evil.com` 这种
/// 「后缀相同但换了一家」不算子域。
test "downgrades and foreign hosts drop credentials" {
  assert_false(
    credential_kept("https://api.example.com/u", "http://api.example.com/u"),
  )
  assert_false(
    credential_kept("https://api.example.com/u", "https://example.com/u"),
  )
  assert_false(
    credential_kept(
      "https://api.example.com/u", "https://example.com.evil.com/u",
    ),
  )
  assert_false(
    credential_kept(
      "https://api.example.com/u", "https://api.example.com:8443/u",
    ),
  )
}

///|
/// 头名大小写不敏感：`authorization` / `content-TYPE` 一样要能被删掉。
test "header matching is case insensitive" {
  let config = @config.Config::new("https://api.example.com/users")
    .with_method(@config.Method::Post)
    .with_header("authorization", "Bearer token")
    .with_header("content-TYPE", "application/json")
  let next = next_hop(
    config.next_redirect(
      "https://api.example.com/users",
      303,
      Some("https://other.example.org/v2"),
    ),
  )
  assert_eq(next.headers.unwrap().length(), 0)
}

///|
/// 用户显式设的 `Host` 头一律丢掉：重定向可能换 host，Host 该由传输层
/// 按新地址重新生成（与 follow-redirects 一致）。
test "the host header is always dropped" {
  let config = @config.Config::new("https://api.example.com/users").with_header(
    "Host", "api.example.com",
  )
  let next = next_hop(
    config.next_redirect("https://api.example.com/users", 302, Some("/v2")),
  )
  assert_eq(next.headers.unwrap().has("Host"), false)
}

///|
/// 不参与改写的字段原样保留；方法即使没配过也在下一跳里写明（GET），
/// 这样交出去的配置自己就能说明「这一跳是怎么发的」。
test "other fields survive the hop" {
  let config = @config.Config::new("/users")
    .with_timeout(2000)
    .with_max_redirects(3)
    .with_response_encoding(@config.ResponseEncoding::Latin1)
    .with_validate_status(fn(_) { true })
    .with_allow_absolute_urls(false)
  let next = next_hop(
    config.next_redirect("https://api.example.com/users", 308, Some("/v2")),
  )
  assert_eq(next.timeout, Some(2000))
  assert_eq(next.max_redirects, Some(3))
  assert_eq(next.response_encoding, Some(@config.ResponseEncoding::Latin1))
  assert_true(next.validate_status is Some(_))
  assert_eq(next.allow_absolute_urls, Some(false))
  assert_eq(next.http_method, Some(@config.Method::Get))
}
