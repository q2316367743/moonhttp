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
  assert_eq(error.response().unwrap().data, { "error": "nope" })
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
    assert_eq(error.unwrap().code(), entry.1)
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
