// 代理的两层用例：
// 1. 拼装契约（不走网络）——代理凭据落在 CONNECT 上、不进目标请求头；
// 2. 端到端——本机 CONNECT 代理 + 本机目标 server，证明 `with_proxy` 的请求
//    真的经过了代理，以及代理拒绝 / 不回应时的错误分类。
// 底层 `@http.Client` 的隧道能力见 docs/09-proxy.md。

///|
/// 代理凭据落在 CONNECT 请求上，不进目标请求头。
///
/// `Proxy-Authorization` 是给代理的，源站既不需要也不该看到它
/// （`redirect.mbt` 同样把它当敏感头）。
test "proxy credentials go to the connect request, not the target" {
  let prepared = @util.build_prepared_request(
    @moonhttp.Config::new("http://example.com/x").with_proxy(
      "127.0.0.1",
      port=9000,
      username="mikeymike",
      password="rapunz3l",
    ),
  ).unwrap()
  let proxy = prepared.proxy.unwrap()
  assert_eq(proxy.url, "http://127.0.0.1:9000")
  // Basic base64("mikeymike:rapunz3l")
  assert_eq(proxy.authorization, Some("Basic bWlrZXltaWtlOnJhcHVuejNs"))
  assert_true(prepared.headers.get("Proxy-Authorization") is None)
}

///|
/// 用户自己在头里设的 `Proxy-Authorization` 也是给代理的：有代理时它被挪到
/// CONNECT 上；`proxy.auth` 存在时覆写它（axios 的规则）。
test "custom proxy-authorization is used unless proxy auth overrides it" {
  let without_auth = @util.build_prepared_request(
    @moonhttp.Config::new("http://example.com/x")
    .with_proxy("127.0.0.1", port=9000)
    .with_header("Proxy-Authorization", "Bearer custom"),
  ).unwrap()
  assert_eq(without_auth.proxy.unwrap().authorization, Some("Bearer custom"))
  assert_true(without_auth.headers.get("Proxy-Authorization") is None)
  let with_auth = @util.build_prepared_request(
    @moonhttp.Config::new("http://example.com/x")
    .with_proxy("127.0.0.1", port=9000, username="u", password="p")
    .with_header("Proxy-Authorization", "Bearer custom"),
  ).unwrap()
  let authorization = with_auth.proxy.unwrap().authorization.unwrap()
  assert_true(authorization.has_prefix("Basic "))
  assert_false(authorization.contains("Bearer"))
}

///|
/// 没配代理时是另一条路径：不重定向流量，用户设的 `Proxy-Authorization`
/// 原样留在请求头里（与加代理之前的行为一致）。
test "without a proxy nothing is rerouted" {
  let prepared = @util.build_prepared_request(
    @moonhttp.Config::new("http://example.com/x").with_header(
      "Proxy-Authorization", "Bearer custom",
    ),
  ).unwrap()
  assert_true(prepared.proxy is None)
  assert_eq(prepared.headers.get("Proxy-Authorization"), Some("Bearer custom"))
}

///|
/// 代理地址按协议拼：`protocol` 缺省是 http；给了端口就写进地址，
/// 没给就留给底层按协议补默认端口（不在这里抄一遍 80/443 的约定）。
test "proxy url follows the protocol and keeps a missing port implicit" {
  let https = @util.build_prepared_request(
    @moonhttp.Config::new("http://example.com/x").with_proxy(
      "proxy.corp",
      protocol=@moonhttp.ProxyProtocol::Https,
    ),
  ).unwrap()
  assert_eq(https.proxy.unwrap().url, "https://proxy.corp")
  let default_scheme = @util.build_prepared_request(
    @moonhttp.Config::new("http://example.com/x").with_proxy(
      "proxy.corp",
      port=3128,
    ),
  ).unwrap()
  assert_eq(default_scheme.proxy.unwrap().url, "http://proxy.corp:3128")
}

///|
/// 极简 CONNECT 代理：把隧道固定打到 `target_port`（本机目标 server），
/// 并把 CONNECT 请求行与它带的凭据记进 `log`。
///
/// 真实代理会解析 `CONNECT host:port` 再去连；这里固定到已知目标是为了不解析
/// 端口——用例自己断言请求行里写的就是那个地址，这个替身仍然如实反映了
/// 「流量确实经代理转发」这件事（隧道打通后两个方向都原样转发字节）。
/// server 由调用方创建：端口要在 `with_task_group` 之外也能读到（断言要用）。
fn tunnel_proxy(
  group : @async.TaskGroup[Unit],
  server : @http.Server,
  target_port : Int,
  log : Array[String],
) -> Unit {
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((request, _body, conn) => {
      let authorization = request.headers
        .get(@http.CaseInsensitiveString("Proxy-Authorization"))
        .unwrap_or("<none>")
      log.push("CONNECT " + request.path + " authorization=" + authorization)
      let upstream = @socket.Tcp::connect_to_host("127.0.0.1", port=target_port)
      defer upstream.close()
      conn..send_response(200, "OK").end_response()
      conn.enter_passthrough_mode()
      @async.with_task_group() <| group => {
        group.spawn_bg(() => conn.write_reader(upstream))
        group.spawn_bg(() => upstream.write_reader(conn))
      }
    })
  }
}

///|
/// 本机目标 server：回一个固定响应，并把收到的请求路径记进 `log`。
fn serve_target(
  group : @async.TaskGroup[Unit],
  server : @http.Server,
  log : Array[String],
) -> Unit {
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((request, _body, conn) => {
      log.push(request.path)
      conn..send_response(200, "OK").write_string("through-the-proxy")
      conn.end_response()
    })
  }
}

///|
/// 端到端：配了代理的请求真的经过了代理——目标 server 收到请求（说明隧道通了），
/// 代理侧看到的是 `CONNECT 目标地址` 与 `Proxy-Authorization`。
async test "request through a proxy reaches the target with credentials" {
  let proxy_log : Array[String] = []
  let target_log : Array[String] = []
  let target = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let target_port = target.addr.port()
  let proxy = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let proxy_port = proxy.addr.port()
  @async.with_task_group() <| group => {
    serve_target(group, target, target_log)
    tunnel_proxy(group, proxy, target_port, proxy_log)
    let client = @moonhttp.Client::new()
    let response = client.request(
      @moonhttp.Config::new("http://127.0.0.1:\{target_port}/hello").with_proxy(
        "127.0.0.1",
        port=proxy_port,
        username="u",
        password="p",
      ),
    )
    assert_eq(response.status, 200)
    assert_eq(response.text(), "through-the-proxy")
  }
  // 目标 server 拿到的路径没变（隧道是透明的）
  assert_eq(target_log[0], "/hello")
  // 代理侧看到的是目标地址而不是代理自己的地址；凭据是 Basic base64("u:p")
  assert_eq(proxy_log.length(), 1)
  assert_eq(
    proxy_log[0],
    "CONNECT 127.0.0.1:\{target_port} authorization=Basic dTpw",
  )
}

///|
/// 代理拒绝建立隧道（CONNECT 非 2xx）→ `ERR_NETWORK`，文案里带状态码。
///
/// 407 是最常见的一种（代理需要认证）。这时响应头还没到手，错误里没有响应，
/// 所以读数只能靠文案——它得说清「是代理拒绝了」，而不是一句抽象的网络失败。
async test "proxy refusing the tunnel reports a readable network error" {
  let proxy = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let proxy_port = proxy.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      proxy.run_forever() <| ((_request, _body, conn) => {
        conn..send_response(407, "ProxyAuthenticationRequired").end_response()
      })
    }
    let client = @moonhttp.Client::new()
    let error = try {
      ignore(
        client.request(
          @moonhttp.Config::new("http://127.0.0.1:1/").with_proxy(
            "127.0.0.1",
            port=proxy_port,
          ),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_eq(error.code(), @moonhttp.ErrorCode::Network)
    assert_true(error.message().contains("407"))
    assert_true(error.response() is None)
  }
}

///|
/// 与代理的 CONNECT 握手也受 `timeout` 约束：代理收下连接却不回应时按超时失败，
/// 而不是无限等下去。
async test "connect handshake respects the timeout" {
  let proxy = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let proxy_port = proxy.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      proxy.run_forever() <| ((_request, _body, conn) => {
        // 什么都不回：客户端会一直等 CONNECT 的响应
        @async.sleep(3000)
        conn.end_response()
      })
    }
    let client = @moonhttp.Client::new()
    let error = try {
      ignore(
        client.request(
          @moonhttp.Config::new("http://127.0.0.1:1/")
          .with_proxy("127.0.0.1", port=proxy_port)
          .with_timeout(300),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::Timeout)
  }
}

///|
/// 给了代理却没给地址（空 host）：这是配置错误，报 `ERR_INVALID_URL`，
/// 而不是把请求直连出去。
///
/// 「给了 proxy 却没 host」的另一半（`host` 整个是 `None`）只有包内构造得出来，
/// 判定 `Proxy::is_usable` 的用例在 `config/proxy_test.mbt`。
async test "a proxy without a host is a configuration error" {
  let client = @moonhttp.Client::new()
  let error = try {
    ignore(client.request(@moonhttp.Config::new("/users").with_proxy("")))
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::InvalidUrl)
  assert_true(error.message().contains("代理"))
}
