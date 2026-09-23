// 请求管线的用例：URL 拼接、query 序列化、三层头优先级、
// body 序列化、认证头、响应体解析方式。

///|
/// 完整走一遍「实例默认配置 + 请求配置 → 合并 → 拼 URL → 拍平头 → 发送 → 解析」。
///
/// 这个用例是整条管线的总检：默认值里的 base_url 与公共头、
/// 请求里的相对路径与 query 参数，必须同时体现到最终发出的请求上。
async test "request merges defaults builds url and parses json" {
  let (client, mock) = client_with(
    raw_response(200, "OK", "{\"id\": 1, \"name\": \"moon\"}"),
  )
  let api = client.create(
    @easy-http-client.Config::default()
    .with_base_url("https://api.example.com")
    .with_common_header("Accept", "application/vnd.api+json")
    .with_method_header(@easy-http-client.Method::Get, "X-Get-Only", "1"),
  )
  let response = api.request(
    @easy-http-client.Config::new("/users").with_params({
      "page": 1,
      "tags": ["a", "b"],
    }),
  )
  // 响应体按 JSON 解析成对象
  assert_eq(response.status, 200)
  assert_eq(response.status_text, "OK")
  assert_eq(response.data, { "id": 1, "name": "moon" })
  assert_true(response.is_success())
  // 请求侧：base_url 拼接 + query 序列化（数组用编码后的 [] ）
  let sent = mock.last_request().unwrap()
  assert_eq(
    sent.url,
    "https://api.example.com/users?page=1&tags%5B%5D=a&tags%5B%5D=b",
  )
  // 请求侧：方法缺省为 GET；三层头都到位
  assert_eq(sent.http_method, @easy-http-client.Method::Get)
  assert_eq(sent.headers.get("Accept"), Some("application/vnd.api+json"))
  assert_eq(sent.headers.get("X-Get-Only"), Some("1"))
  // 没有 data 时不带 body
  assert_eq(sent.body, None)
}

///|
/// 请求级平铺头优先级最高，能盖掉 common 层与按方法层的同名头。
async test "request headers win over layered defaults" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @easy-http-client.Config::default()
    .with_common_header("X-Layer", "common")
    .with_method_header(@easy-http-client.Method::Post, "X-Layer", "method"),
  )
  // POST：按方法层盖掉 common 层，请求级再盖掉按方法层
  ignore(
    api.request(
      @easy-http-client.Config::new("https://api.example.com/x")
      .with_method(@easy-http-client.Method::Post)
      .with_header("X-Layer", "request"),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("X-Layer"),
    Some("request"),
  )
  // 同一个实例换成 GET：按方法层不匹配，落到 common 层
  ignore(
    api.request(@easy-http-client.Config::new("https://api.example.com/x")),
  )
  assert_eq(mock.last_request().unwrap().headers.get("X-Layer"), Some("common"))
}

///|
/// body 的序列化：Json 对象变成 JSON 文本并自动补 `Content-Type`，
/// 但用户显式设置的类型不会被盖掉。
async test "json body sets content type only when absent" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.request(
      @easy-http-client.Config::new("/users")
      .with_method(@easy-http-client.Method::Post)
      .with_data({ "name": "moon" }),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(sent.headers.get("Content-Type"), Some("application/json"))
  assert_eq(@utf8.decode_lossy(sent.body.unwrap()), "{\"name\":\"moon\"}")
  // 用户显式指定 Content-Type 时保持原样
  ignore(
    client.request(
      @easy-http-client.Config::new("/users")
      .with_method(@easy-http-client.Method::Post)
      .with_data({ "name": "moon" })
      .with_header("Content-Type", "application/vnd.custom+json"),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("Content-Type"),
    Some("application/vnd.custom+json"),
  )
}

///|
/// 字符串 body 原样发送，不推断类型（无法判断用户想发 JSON 还是纯文本）。
async test "string body is sent verbatim without content type" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.request(
      @easy-http-client.Config::new("/text")
      .with_method(@easy-http-client.Method::Post)
      .with_data("raw text body"),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(@utf8.decode_lossy(sent.body.unwrap()), "raw text body")
  assert_eq(sent.headers.get("Content-Type"), None)
}

///|
/// auth 配置生成 Basic 认证头，且不覆盖用户自己写的 Authorization。
async test "auth produces basic authorization header" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.request(
      @easy-http-client.Config::new("/private").with_auth("alice", "s3cret"),
    ),
  )
  // base64("alice:s3cret")
  assert_eq(
    mock.last_request().unwrap().headers.get("Authorization"),
    Some("Basic YWxpY2U6czNjcmV0"),
  )
  ignore(
    client.request(
      @easy-http-client.Config::new("/private")
      .with_auth("alice", "s3cret")
      .with_header("Authorization", "Bearer token"),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("Authorization"),
    Some("Bearer token"),
  )
}

///|
/// `response_type` 的三个取值：Auto 解析、Text 不解析、Json 强制解析。
async test "response type controls body parsing" {
  let (client, _) = client_with(raw_response(200, "OK", "{\"a\": 1}"))
  let as_object = client.request(@easy-http-client.Config::new("/x"))
  assert_eq(as_object.data, { "a": 1 })
  let as_text = client.request(
    @easy-http-client.Config::new("/x").with_response_type(
      @easy-http-client.ResponseType::Text,
    ),
  )
  assert_eq(as_text.data, "{\"a\": 1}")
  // 文本形式也能拿到原始字符串
  assert_eq(as_text.text(), "{\"a\": 1}")
}

///|
/// Auto 模式下解析失败不报错，把原文交给调用方（对应 axios 的 forcedJSONParsing）。
async test "auto response type falls back to raw text" {
  let (client, _) = client_with(raw_response(200, "OK", "not json at all"))
  let response = client.request(@easy-http-client.Config::new("/x"))
  assert_eq(response.data, "not json at all")
  assert_eq(response.text(), "not json at all")
}

///|
/// 强制 JSON 时解析失败要报错，并把响应挂上，调用方仍能看到状态码。
async test "forced json response type reports parse failure" {
  let (client, _) = client_with(raw_response(200, "OK", "<html>nope</html>"))
  let error = try {
    ignore(
      client.request(
        @easy-http-client.Config::new("/x").with_response_type(
          @easy-http-client.ResponseType::Json,
        ),
      ),
    )
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @easy-http-client.ErrorCode::BadResponse)
  assert_eq(error.response().unwrap().status, 200)
}

///|
/// 绝对地址默认直连；关掉 allow_absolute_urls 后会被拼到 base_url 后面。
async test "allow absolute urls can be turned off" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @easy-http-client.Config::default().with_base_url("https://api.example.com"),
  )
  ignore(
    api.request(@easy-http-client.Config::new("https://other.example.com/x")),
  )
  assert_eq(mock.last_request().unwrap().url, "https://other.example.com/x")
  ignore(
    api.request(
      @easy-http-client.Config::new("https://other.example.com/x").with_allow_absolute_urls(
        false,
      ),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().url,
    "https://api.example.com/https://other.example.com/x",
  )
}

///|
/// `response_type = Json` 解析成功时，data 是解析后的对象（失败路径见 error_test）。
async test "forced json response type parses on success" {
  let (client, _) = client_with(raw_response(200, "OK", "{\"a\": 1}"))
  let response = client.request(
    @easy-http-client.Config::new("/x").with_response_type(
      @easy-http-client.ResponseType::Json,
    ),
  )
  assert_eq(response.data, { "a": 1 })
}

///|
/// `content_length` 是原始字节数而不是字符数：中文在 UTF-8 下占 3 字节。
async test "response content length counts bytes" {
  let (client, _) = client_with(raw_response(200, "OK", "中文"))
  let response = client.request(@easy-http-client.Config::new("/x"))
  assert_eq(response.content_length(), 6)
  assert_eq(response.text(), "中文")
}
