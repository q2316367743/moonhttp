// 错误路径的用例：状态码校验分档、传输层错误映射、
// 以及错误里携带的上下文。

///|
/// 4xx 映射成 `BadRequest`，5xx 映射成 `BadResponse`，
/// 两者都把响应挂在错误上，便于调用方读取服务端返回的错误详情。
async test "status validation maps 4xx and 5xx to distinct codes" {
  let (client, _) = client_with(
    raw_response(404, "Not Found", "{\"error\": \"nope\"}"),
  )
  let error = try {
    ignore(client.request(@moonhttp.Config::new("/missing")))
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::BadRequest)
  assert_eq(error.response().unwrap().data, "{\"error\": \"nope\"}")
  // 5xx 归到另一档
  let (client, _) = client_with(
    raw_response(500, "Internal Server Error", "{}"),
  )
  let error = try {
    ignore(client.request(@moonhttp.Config::new("/boom")))
    None
  } catch {
    error => Some(error)
  }
  assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::BadResponse)
}

///|
/// 自定义校验规则可以放行 4xx，这时 `request` 正常返回响应，
/// 调用方靠 `is_success` 自行判断。
async test "custom validate status can accept 4xx" {
  let (client, _) = client_with(raw_response(404, "Not Found", "{}"))
  let api = client.create(
    @moonhttp.Config::default().with_validate_status(fn(status) {
      status >= 200 && status < 500
    }),
  )
  let response = api.request(@moonhttp.Config::new("/missing"))
  assert_eq(response.status, 404)
  assert_false(response.is_success())
}

///|
/// 没有 url 且没有 base_url 时，在发请求之前就以 `InvalidUrl` 失败。
async test "missing url fails with invalid url" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let error = try {
    ignore(client.request(@moonhttp.Config::default()))
    None
  } catch {
    error => Some(error)
  }
  assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::InvalidUrl)
  // 失败发生在本地，不该产生任何实际发送
  assert_eq(mock.request_count(), 0)
}

///|
/// 传输层的三类错误分别映射成 Timeout / Network / NotSupported，
/// 调用方不需要认识底层错误类型。
async test "transport failures map to error codes" {
  let cases : Array[(@transport.TransportError, @moonhttp.ErrorCode)] = [
    (@transport.TransportError::Timeout, @moonhttp.ErrorCode::Timeout),
    (
      @transport.TransportError::Network("connection refused"),
      @moonhttp.ErrorCode::Network,
    ),
    (
      @transport.TransportError::Unsupported("no websocket"),
      @moonhttp.ErrorCode::NotSupported,
    ),
  ]
  for entry in cases {
    let mock = @transport.MockTransport::failing(entry.0)
    let transport : &@transport.Transport = mock
    let client = @moonhttp.Client::new(transport~)
    let error = try {
      ignore(client.request(@moonhttp.Config::new("/x")))
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_eq(error.code(), entry.1)
    // 失败发生在收到响应头之前：确实没有响应可挂
    assert_true(error.response() is None)
  }
}

///|
/// 错误里带有已合并的配置，便于排查「到底是哪一层配置不对」。
async test "error carries the merged config" {
  let (client, _) = client_with(
    raw_response(500, "Internal Server Error", "{}"),
  )
  let api = client.create(
    @moonhttp.Config::default().with_base_url("https://api.example.com"),
  )
  let error = try {
    ignore(api.request(@moonhttp.Config::new("/x")))
    None
  } catch {
    error => Some(error)
  }
  let config = error.unwrap().config()
  assert_eq(config.base_url, Some("https://api.example.com"))
  assert_eq(config.url, Some("/x"))
}

///|
/// 错误的访问器与渲染：`to_string` 形如 `错误码: 描述`，Show 与它同格式。
async test "http error accessors and rendering" {
  let (client, _) = client_with(raw_response(404, "Not Found", "{}"))
  let error = try {
    ignore(client.request(@moonhttp.Config::new("/missing")))
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::BadRequest)
  assert_eq(error.message(), "请求失败，状态码 404")
  assert_eq(error.to_string(), "ERR_BAD_REQUEST: 请求失败，状态码 404")
  assert_eq("\{error}", "ERR_BAD_REQUEST: 请求失败，状态码 404")
  assert_eq(error.info().code, @moonhttp.ErrorCode::BadRequest)
  assert_eq(error.config().url, Some("/missing"))
}

///|
/// 每个分类都有稳定的 axios 风格错误码字符串——这是对外契约的一部分。
test "error code rendering covers every category" {
  let cases : Array[(@moonhttp.ErrorCode, String)] = [
    (@moonhttp.ErrorCode::BadRequest, "ERR_BAD_REQUEST"),
    (@moonhttp.ErrorCode::BadResponse, "ERR_BAD_RESPONSE"),
    (@moonhttp.ErrorCode::Network, "ERR_NETWORK"),
    // axios 默认的超时错误码就是 ECONNABORTED（不是 ETIMEDOUT）
    (@moonhttp.ErrorCode::Timeout, "ECONNABORTED"),
    (@moonhttp.ErrorCode::InvalidUrl, "ERR_INVALID_URL"),
    (@moonhttp.ErrorCode::NotSupported, "ERR_NOT_SUPPORT"),
  ]
  for entry in cases {
    assert_eq(entry.0.to_string(), entry.1)
    assert_eq("\{entry.0}", entry.1)
  }
}

// ---------------------------------------------------------------------------
// 失败也带着东西：响应头到手之后才失败的请求，错误里挂着已经收到的响应
// ---------------------------------------------------------------------------

///|
/// 起一个「发完响应头与半截正文就挂住」的本机 server，返回它的端口。
///
/// 挂住（既不发更多数据、也不结束响应）是为了把客户端钉在「读到一半」这个
/// 状态上：配上短的 `timeout`，客户端读到那半截之后就等不到数据，按超时失败
/// ——正好检验「失败时已经读到的东西有没有被丢掉」。
///
/// 错误类型是开放的（`raise` 不带类型）：`@socket.Addr::parse` 与
/// `@http.Server` 的构造本身就是开放错误类型，测试用例里再收敛没有意义。
async fn stalling_server(
  group : @async.TaskGroup[Unit],
  status : Int,
  status_text : String,
  partial : String,
) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((_request, _body, conn) => {
      conn..send_response(status, status_text).flush()
      conn..write_string(partial).flush()
      @async.sleep(3000)
      conn.end_response()
    })
  }
  port
}

///|
/// `request` 在读到一半失败时，错误里带着已经收到的响应：状态行、响应头，
/// 以及**读到的部分正文**。
///
/// 这条钉住的是「传输层失败不等于什么都没收到」：服务端已经回了 500 与半截
/// 错误正文，客户端读剩下的部分时超时——如果不把已读到的挂到错误上，
/// 调用方拿到的就只有一个 `Timeout`，看不到服务端写下的原因。
async test "request keeps the partial response when the body read fails" {
  @async.with_task_group() <| group => {
    let port = stalling_server(
      group, 500, "Internal Server Error", "{\"error\": \"too ",
    )
    let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
    let client = @moonhttp.Client::new(transport~)
    let error = try {
      ignore(
        client.request(
          @moonhttp.Config::new("http://127.0.0.1:\{port}/boom").with_timeout(
            300,
          ),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    // 错误码仍然是「失败本身」的分类，不因为挂上了响应就改用状态码分档
    assert_eq(error.code(), @moonhttp.ErrorCode::Timeout)
    let received = error.response().unwrap()
    assert_eq(received.status, 500)
    assert_eq(received.status_text, "Internal Server Error")
    assert_eq(received.data, "{\"error\": \"too ")
  }
}

///|
/// 流式入口读错误体时同理：状态码不通过 → 读错误体 → 读到一半超时。
/// 错误里既有状态码 500，也有已经读到的那半截错误正文。
async test "stream keeps the partial error body when reading it fails" {
  @async.with_task_group() <| group => {
    let port = stalling_server(
      group, 500, "Internal Server Error", "{\"error\": \"too ",
    )
    let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
    let client = @moonhttp.Client::new(transport~)
    let error = try {
      ignore(
        client.stream(
          @moonhttp.Config::new("http://127.0.0.1:\{port}/boom").with_timeout(
            300,
          ),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_eq(error.code(), @moonhttp.ErrorCode::Timeout)
    let received = error.response().unwrap()
    assert_eq(received.status, 500)
    assert_eq(received.data, "{\"error\": \"too ")
  }
}

///|
/// 流式读取（`read_all`）在中途失败时，已经读到的字节也挂在错误上——
/// 下载断在半路时，那半截就是现场。
async test "stream read_all keeps the bytes received before the failure" {
  @async.with_task_group() <| group => {
    let port = stalling_server(group, 200, "OK", "0123456789")
    let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
    let client = @moonhttp.Client::new(transport~)
    let download = client.stream(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/file").with_timeout(300),
    )
    let error = try {
      ignore(download.read_all())
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_eq(error.code(), @moonhttp.ErrorCode::Timeout)
    // 状态码与已读到的字节都在错误里：不用再发一次请求就知道断在哪
    let received = error.response().unwrap()
    assert_eq(received.status, 200)
    assert_eq(received.data, "0123456789")
  }
}
