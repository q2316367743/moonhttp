// 代理配置的形状与合并：`with_proxy` 构建器、`Proxy::is_usable` 判定、
// 渲染脱敏，以及跨「实例默认值 / 请求级」的逐字段合并。
// 真正把流量导向代理的部分在传输层与根包的用例里（`src/proxy_test.mbt`）。

///|
/// `with_proxy` 的四个可选参数各自落到 `Proxy` 的对应字段上；
/// 不给凭据时不产生 `auth`（匿名代理）。
test "proxy builder records host port protocol and credentials" {
  let config = @config.Config::default().with_proxy(
    "127.0.0.1",
    port=9000,
    username="mikeymike",
    password="rapunz3l",
  )
  let proxy = config.proxy.unwrap()
  assert_eq(proxy.host, Some("127.0.0.1"))
  assert_eq(proxy.port, Some(9000))
  assert_eq(proxy.protocol, None)
  let auth = proxy.auth.unwrap()
  assert_eq(auth.username, Some("mikeymike"))
  assert_eq(auth.password, Some("rapunz3l"))
}

///|
/// 只给 host 就是匿名代理：其余字段保持「未提供」，交给下层兜底
/// （protocol 缺省 http、port 缺省由协议决定）。
test "proxy with only a host leaves the rest unset" {
  let proxy = @config.Config::default().with_proxy("proxy.local").proxy.unwrap()
  assert_eq(proxy.host, Some("proxy.local"))
  assert_eq(proxy.port, None)
  assert_eq(proxy.protocol, None)
  assert_true(proxy.auth is None)
}

///|
/// 协议是显式枚举（拼错协议名是编译错误），渲染成 URL 里那个小写取值。
test "proxy protocol renders as a scheme name" {
  let https = @config.ProxyProtocol::Https
  let http = @config.ProxyProtocol::Http
  assert_eq(https.to_string(), "https")
  assert_eq(http.to_string(), "http")
  let proxy = @config.Config::default().with_proxy(
    "proxy.corp",
    port=8443,
    protocol=https,
  ).proxy.unwrap()
  assert_eq(proxy.protocol, Some(https))
}

///|
/// 只有 host 是非空字符串才算「能用」。
///
/// 这条判定是「给了 proxy 却没给 host」这种配置错误的唯一入口：
/// 上层据此报错，而不是当成没配代理——静默直连会让本该走代理的请求
/// 从别的路出去，比报错危险得多。
test "proxy needs a non-empty host to be usable" {
  let usable = @config.Config::default().with_proxy("127.0.0.1").proxy.unwrap()
  assert_true(usable.is_usable())
  assert_false(@config.Proxy::default().is_usable())
  let blank : @config.Proxy = { ..@config.Proxy::default(), host: Some("  "), }
  assert_false(blank.is_usable())
}

///|
/// 渲染把代理凭据脱敏：密码不出现在任何地方（配置经常整体进日志与断言信息）。
test "proxy rendering redacts credentials" {
  let rendered = @config.Config::default()
    .with_proxy(
      "127.0.0.1",
      port=9000,
      protocol=@config.ProxyProtocol::Http,
      username="mikeymike",
      password="rapunz3l",
    )
    .to_string()
  assert_true(
    rendered.contains(
      "proxy: Proxy { protocol: http, host: 127.0.0.1, port: 9000, auth: Auth { username: mikeymike, password: <redacted> } }",
    ),
  )
  assert_false(rendered.contains("rapunz3l"))
}

///|
/// 合并时请求级优先：两侧都给了代理地址时，请求级的那份赢。
///
/// 「请求级只给凭据、地址沿用默认值」的逐字段填充见白盒测试（`merge_wbtest.mbt`）：
/// 那种配置只有包内构造得出来。
test "request level proxy wins over the instance default" {
  let base = @config.Config::default().with_proxy("127.0.0.1", port=9000)
  let request = @config.Config::default().with_proxy("proxy.corp", port=3128)
  let merged = @config.merge_config(base, request).proxy.unwrap()
  assert_eq(merged.host, Some("proxy.corp"))
  assert_eq(merged.port, Some(3128))
  // 请求级没提代理时，默认值里的代理原样保留
  let inherited = @config.merge_config(base, @config.Config::default()).proxy.unwrap()
  assert_eq(inherited.host, Some("127.0.0.1"))
}

///|
/// 重定向的下一跳沿用同一份代理：代理回答的是「怎么出去」，不是「发给谁」，
/// 跨 host 跳转丢的是凭据（见 redirect.mbt），不是出口。
test "redirects keep the proxy setting" {
  let config = @config.Config::new("http://a.example.com/x").with_proxy(
    "127.0.0.1",
    port=9000,
  )
  let next = config
    .next_redirect(
      "http://a.example.com/x",
      302,
      Some("http://b.example.com/y"),
    )
    .unwrap()
  assert_eq(next.url, Some("http://b.example.com/y"))
  assert_eq(next.proxy.unwrap().host, Some("127.0.0.1"))
  assert_eq(next.proxy.unwrap().port, Some(9000))
}
