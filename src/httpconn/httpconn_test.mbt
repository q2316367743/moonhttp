// httpconn 的无网络测试：URL 解析与 Host 生成（纯逻辑）、错误分类
// （连本机必然拒连的端口）。「真实链路」的测试靶子由 owner 提供
// （docs/17 口径 6：WebDAV 服务器实测），不在这层模拟网络。

///|
/// 目标解析：scheme 决定默认端口与是否 TLS，路径缺省补 `/`。
test "parse target splits scheme, host, port and path" {
  let plain = @httpconn.parse_target("http://api.example.com/users?q=1")
  assert_eq(plain.scheme, "http")
  assert_false(plain.use_tls)
  assert_eq(plain.host, "api.example.com")
  assert_eq(plain.port, 80)
  assert_eq(plain.target, "/users?q=1")
  let secure = @httpconn.parse_target("https://api.example.com:8443/v2")
  assert_true(secure.use_tls)
  assert_eq(secure.port, 8443)
  assert_eq(secure.target, "/v2")
  let bare = @httpconn.parse_target("https://api.example.com")
  assert_eq(bare.port, 443)
  assert_eq(bare.target, "/")
}

///|
/// IPv6 只认方括号形式：方括号外的冒号才是 host:port 分隔符。
test "ipv6 literals parse with brackets" {
  let with_port = @httpconn.parse_target("http://[::1]:8080/x")
  assert_eq(with_port.host, "[::1]")
  assert_eq(with_port.port, 8080)
  let no_port = @httpconn.parse_target("http://[::1]/x")
  assert_eq(no_port.host, "[::1]")
  assert_eq(no_port.port, 80)
}

///|
/// 发不出去的地址显式失败：相对地址、不认识的协议、缺主机、坏端口。
/// （`socks5` 是例外：parse_target 认识它——代理地址解析要用——
/// 但作为请求目标会在 send 层被拒，见下一条用例。）
test "unsendable targets are rejected as unsupported" {
  for
    url in [
      "/relative", "ftp://example.com/file", "http:///no-host", "http://host:0/",
      "http://host:99999/", "http://host:80a/",
    ] {
    let error = try {
      ignore(@httpconn.parse_target(url))
      None
    } catch {
      error => Some(error)
    }
    assert_true(
      error is Some(@transport.TransportError::Unsupported(_)),
      msg="expect Unsupported for \{url}",
    )
  }
}

///|
/// socks5 作为请求目标在 send 层被拒（作为代理地址则由代理拨号处理）。
async test "socks5 request target is rejected at the send layer" {
  let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()
  let error = try {
    ignore(
      transport.send(
        prepared(@transport.Method::Get, "socks5://example.com:1080/x"),
      ),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@transport.TransportError::Unsupported(_)))
}

///|
/// `Host` 头：默认端口省略（RFC 9112 §7.2），非默认端口必须带上。
test "host header omits the default port only" {
  assert_eq(
    @httpconn.host_header(@httpconn.parse_target("http://api.example.com/x")),
    "api.example.com",
  )
  assert_eq(
    @httpconn.host_header(
      @httpconn.parse_target("https://api.example.com:8443/x"),
    ),
    "api.example.com:8443",
  )
  assert_eq(
    @httpconn.host_header(
      @httpconn.parse_target("http://api.example.com:8080/"),
    ),
    "api.example.com:8080",
  )
}

///|
/// 构造 PreparedRequest 的便捷函数（字段与 transport_test 同一套）。
fn prepared(
  meth : @transport.Method,
  url : String,
) -> @transport.PreparedRequest {
  {
    http_method: meth,
    url,
    headers: @transport.Headers::new(),
    body: None,
    timeout: Some(3000),
    proxy: None,
    on_upload_progress: None,
    signal: None,
  }
}

///|
/// 非法方法 token 在建连**之前**被拦下：url 特意用本机必然拒连的地址，
/// 如果先拨号，拿到的是 Network 而不是 Unsupported——正好暴露顺序错误。
async test "invalid method token is rejected before dialing" {
  let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()
  let error = try {
    ignore(
      transport.send(
        prepared(@transport.Method::Other("BAD METHOD"), "http://127.0.0.1:1/"),
      ),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@transport.TransportError::Unsupported(_)))
}

///|
/// 连接拒绝 → Network：错误映射本身，不依赖外网。
async test "connection refused is classified as network error" {
  let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()
  let error = try {
    ignore(
      transport.send(prepared(@transport.Method::Get, "http://127.0.0.1:1/")),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@transport.TransportError::Network(_)))
}

///|
/// 自定义方法穿过 token 校验、真的去拨号（拒连被归类为 Network）——
/// 与旧栈「Other 在建连前被拦」相对照，这正是自研路径解锁自定义方法的
/// 可观察证据（docs/16 的目标）。
async test "custom method passes validation and reaches the network layer" {
  let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()
  let error = try {
    ignore(
      transport.send(
        prepared(@transport.Method::Other("PROPFIND"), "http://127.0.0.1:1/"),
      ),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@transport.TransportError::Network(_)))
}
