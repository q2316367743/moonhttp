// 重定向的端到端用例：跟随、改写规则、上限、关闭跟随、凭据，
// 以及一条真实连接的用例（证明丢掉 3xx 正文后下一跳照常完成）。

///|
/// 造一份带 `Location` 的 3xx 原始响应。
fn redirect_response(
  status : Int,
  location : String,
  body : String,
) -> @transport.RawResponse {
  {
    status,
    status_text: "Found",
    headers: @transport.Headers::new().set("Location", location),
    body: @transport.ResponseBody::from_bytes(@utf8.encode(body)),
  }
}

///|
/// 造一个按队列返回响应的实例（重定向需要多份响应），并把 Mock 一起返回。
fn client_with_chain(
  responses : Array[@transport.RawResponse],
) -> (@moonhttp.Client, @transport.MockTransport) {
  let mock = @transport.MockTransport::from_responses(responses)
  let transport : &@transport.Transport = mock
  (@moonhttp.Client::new(transport~), mock)
}

///|
/// 跑一次请求并把抛出的错误取出来；没抛错说明用例的前提不成立。
async fn request_error(
  client : @moonhttp.Client,
  config : @moonhttp.Config,
) -> @moonhttp.HttpError {
  let result = try {
    ignore(client.request(config))
    None
  } catch {
    error => Some(error)
  }
  result.unwrap()
}

///|
/// 默认跟随：302 之后交出去的是**第二跳**的响应，两跳的地址都记录在 Mock 上；
/// `response.config` 是最后一跳的配置，`config.url` 就是真正产出响应的地址。
async test "request follows a redirect and returns the final response" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "/v2/users", "moved"),
    raw_response(200, "OK", "{\"id\": 1}"),
  ])
  let response = client.request(
    @moonhttp.Config::new("https://api.example.com/users"),
  )
  assert_eq(response.status, 200)
  assert_eq(response.text(), "{\"id\": 1}")
  assert_eq(mock.request_count(), 2)
  let sent = mock.received()
  assert_eq(sent[0].url, "https://api.example.com/users")
  assert_eq(sent[1].url, "https://api.example.com/v2/users")
  assert_eq(response.config.url, Some("https://api.example.com/v2/users"))
}

///|
/// 302 把 POST 降级成 GET：第二跳不带 body，也不带 `content-*`。
async test "a 302 rewrites POST to GET and drops the entity" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "/v2/users", ""),
    raw_response(200, "OK", "ok"),
  ])
  ignore(
    client.request(
      @moonhttp.Config::new("https://api.example.com/users")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_json({ "name": "moon" }),
    ),
  )
  let sent = mock.received()
  assert_eq(sent[0].http_method, @moonhttp.Method::Post)
  assert_true(sent[0].body is Some(_))
  assert_eq(sent[0].headers.get("Content-Type"), Some("application/json"))
  assert_eq(sent[1].http_method, @moonhttp.Method::Get)
  assert_eq(sent[1].body, None)
  assert_eq(sent[1].headers.has("Content-Type"), false)
}

///|
/// 307 是「原样重发」：方法与 body 都跟着过去。
async test "a 307 keeps the method and resends the entity" {
  let (client, mock) = client_with_chain([
    redirect_response(307, "/v2/users", ""),
    raw_response(200, "OK", "ok"),
  ])
  ignore(
    client.request(
      @moonhttp.Config::new("https://api.example.com/users")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_json({ "name": "moon" }),
    ),
  )
  let sent = mock.received()
  assert_eq(sent[1].http_method, @moonhttp.Method::Post)
  assert_true(sent[1].body is Some(_))
  assert_eq(sent[1].headers.get("Content-Type"), Some("application/json"))
}

///|
/// 相对 `Location` 相对**实际发出去的地址**解析（含 query），
/// 下一跳不会再追加一次 `params`。
async test "relative locations resolve against the url that was sent" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "../v2/users?page=2", ""),
    raw_response(200, "OK", "ok"),
  ])
  ignore(
    client.request(
      @moonhttp.Config::new("/api/v1/users")
      .with_base_url("https://api.example.com")
      .with_params({ "page": 1 }),
    ),
  )
  let sent = mock.received()
  assert_eq(sent[0].url, "https://api.example.com/api/v1/users?page=1")
  assert_eq(sent[1].url, "https://api.example.com/api/v2/users?page=2")
}

///|
/// 超过上限抛 `TooManyRedirects`：错误码与 axios 透传的 follow-redirects 码同名，
/// 错误里带着**最后那个 3xx 响应**（这一条与 axios 不同，见 docs/08-redirects.md）。
async test "redirects beyond the limit raise TooManyRedirects" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "/a", "step"),
    redirect_response(302, "/b", "step"),
    redirect_response(302, "/c", "step"),
  ])
  let error = request_error(
    client,
    @moonhttp.Config::new("https://api.example.com/start").with_max_redirects(2),
  )
  assert_eq(error.code(), @moonhttp.ErrorCode::TooManyRedirects)
  assert_eq(error.code().to_string(), "ERR_FR_TOO_MANY_REDIRECTS")
  // 上限 2：跟了两跳，第 3 个重定向触发上限
  assert_eq(mock.request_count(), 3)
  let response = error.response().unwrap()
  assert_eq(response.status, 302)
  assert_eq(response.headers.get("Location"), Some("/c"))
  assert_eq(response.text(), "step")
  // 错误里的配置是产出该 3xx 的那一跳
  assert_eq(error.config().url, Some("https://api.example.com/b"))
}

///|
/// 内置默认上限是 5：跟满 5 跳之后，第 6 个重定向才报错。
/// 改默认值会让这条用例失败——这是故意的，默认值属于公开契约。
async test "the builtin limit is five hops" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "/1", ""),
    redirect_response(302, "/2", ""),
    redirect_response(302, "/3", ""),
    redirect_response(302, "/4", ""),
    redirect_response(302, "/5", ""),
    redirect_response(302, "/6", ""),
    raw_response(200, "OK", "done"),
  ])
  let error = request_error(
    client,
    @moonhttp.Config::new("https://api.example.com/0"),
  )
  assert_eq(error.code(), @moonhttp.ErrorCode::TooManyRedirects)
  assert_eq(mock.request_count(), 6)
}

///|
/// `max_redirects = 0` 表示不跟随：3xx 原样交给状态码校验，
/// 默认规则只放行 2xx，所以报 `BadResponse`，响应（含 `Location`）挂在错误上。
async test "max_redirects 0 hands the 3xx to status validation" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "/v2", "moved"),
  ])
  let error = request_error(
    client,
    @moonhttp.Config::new("https://api.example.com/users").with_max_redirects(0),
  )
  assert_eq(error.code(), @moonhttp.ErrorCode::BadResponse)
  assert_eq(mock.request_count(), 1)
  let response = error.response().unwrap()
  assert_eq(response.status, 302)
  assert_eq(response.headers.get("Location"), Some("/v2"))
  assert_eq(response.text(), "moved")
}

///|
/// 跨 host 的重定向丢掉凭据（`auth` 与显式设的 `Authorization` 都不带过去），
/// 与凭据无关的头照旧带。
async test "cross host redirects drop the credentials" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "https://other.example.org/v2", ""),
    raw_response(200, "OK", "ok"),
  ])
  ignore(
    client.request(
      @moonhttp.Config::new("https://api.example.com/users")
      .with_auth("alice", "s3cret")
      .with_header("X-Trace", "1"),
    ),
  )
  let sent = mock.received()
  assert_true(sent[0].headers.has("Authorization"))
  assert_eq(sent[1].headers.has("Authorization"), false)
  assert_eq(sent[1].headers.get("X-Trace"), Some("1"))
}

///|
/// 流式入口走同一段循环：`stream` 拿到的也是最后一跳的响应。
async test "stream follows redirects as well" {
  let (client, mock) = client_with_chain([
    redirect_response(302, "/v2/data", ""),
    raw_response(200, "OK", "payload"),
  ])
  let stream = client.stream(
    @moonhttp.Config::new("https://api.example.com/data"),
  )
  assert_eq(stream.status, 200)
  assert_eq(stream.config.url, Some("https://api.example.com/v2/data"))
  assert_eq(stream.read_all(), b"payload")
  assert_eq(mock.request_count(), 2)
}

///|
/// 真实连接上的重定向：本机 server 对 `/events` 回 302（还写了一段正文），
/// 对 `/stream` 回 SSE 事件流。
///
/// 这条用例同时钉住两件事：一是 `sse` 入口也跟随（三个入口共用同一段循环），
/// 二是 3xx 那条连接被正确释放——跟随之前客户端会关掉它的响应体，
/// 关得不干净这里会在下一跳上挂住或读不出事件。
async test "sse follows a redirect over a real connection" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((request, _body, conn) => {
        if request.path == "/events" {
          let headers : Map[@http.CaseInsensitiveString, String] = Map([])
          headers[@http.CaseInsensitiveString("Location")] = "/stream"
          conn..send_response(302, "Found", extra_headers=headers).flush()
          // 3xx 的正文故意写一段：客户端应当丢掉它并照常跟到下一跳
          conn..write_string("moved").end_response()
        } else {
          conn
          ..send_response(200, "OK", extra_headers=event_stream_headers())
          .flush()
          conn..write_string("data: hello\n\n").end_response()
        }
      })
    }
    let events = @moonhttp.Client::new().sse(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/events"),
    )
    assert_eq(events.status, 200)
    assert_eq(events.next_event().unwrap().data, "hello")
    assert_eq(events.next_event(), None)
  }
}
