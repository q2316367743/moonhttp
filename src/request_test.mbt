// 请求管线的用例：URL 拼接、query 序列化、三层头优先级、
// body 序列化、认证头、响应体读取。
//
// AGENTS.md RL-04 例外声明：本文件是根包（`src/` 根目录）的测试文件，已超过 300 行，
// 按 RL-04 为根包文件开出的例外处理——上限 1000 行，并在此声明。

///|
/// 完整走一遍「实例默认配置 + 请求配置 → 合并 → 拼 URL → 拍平头 → 发送 → 解码」。
///
/// 这个用例是整条管线的总检：默认值里的 base_url 与公共头、
/// 请求里的相对路径与 query 参数，必须同时体现到最终发出的请求上。
async test "request merges defaults builds url and reads body" {
  let (client, mock) = client_with(
    raw_response(200, "OK", "{\"id\": 1, \"name\": \"moon\"}"),
  )
  let api = client.create(
    @moonhttp.Config::default()
    .with_base_url("https://api.example.com")
    .with_common_header("Accept", "application/vnd.api+json")
    .with_method_header(@moonhttp.Method::Get, "X-Get-Only", "1"),
  )
  let response = api.request(
    @moonhttp.Config::new("/users").with_params({
      "page": 1,
      "tags": ["a", "b"],
    }),
  )
  // 响应体读法与请求侧无关：这里是原文
  assert_eq(response.status, 200)
  assert_eq(response.status_text, "OK")
  assert_eq(response.text(), "{\"id\": 1, \"name\": \"moon\"}")
  assert_true(response.is_success())
  // 请求侧：base_url 拼接 + query 序列化（数组用编码后的 [] ）
  let sent = mock.last_request().unwrap()
  assert_eq(
    sent.url,
    "https://api.example.com/users?page=1&tags%5B%5D=a&tags%5B%5D=b",
  )
  // 请求侧：方法缺省为 GET；三层头都到位
  assert_eq(sent.http_method, @moonhttp.Method::Get)
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
    @moonhttp.Config::default()
    .with_common_header("X-Layer", "common")
    .with_method_header(@moonhttp.Method::Post, "X-Layer", "method"),
  )
  // POST：按方法层盖掉 common 层，请求级再盖掉按方法层
  ignore(
    api.request(
      @moonhttp.Config::new("https://api.example.com/x")
      .with_method(@moonhttp.Method::Post)
      .with_header("X-Layer", "request"),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("X-Layer"),
    Some("request"),
  )
  // 同一个实例换成 GET：按方法层不匹配，落到 common 层
  ignore(api.request(@moonhttp.Config::new("https://api.example.com/x")))
  assert_eq(mock.last_request().unwrap().headers.get("X-Layer"), Some("common"))
}

///|
/// body 的序列化：JSON 值变成 JSON 文本并自动补 `Content-Type`，
/// 但用户显式设置的类型不会被盖掉。
async test "json body sets content type only when absent" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.request(
      @moonhttp.Config::new("/users")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_json({ "name": "moon" }),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(sent.headers.get("Content-Type"), Some("application/json"))
  assert_eq(@utf8.decode_lossy(sent.body.unwrap()), "{\"name\":\"moon\"}")
  // 用户显式指定 Content-Type 时保持原样
  ignore(
    client.request(
      @moonhttp.Config::new("/users")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_json({ "name": "moon" })
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
      @moonhttp.Config::new("/text")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_str("raw text body"),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(@utf8.decode_lossy(sent.body.unwrap()), "raw text body")
  assert_eq(sent.headers.get("Content-Type"), None)
  // 想发 JSON 文本就自己声明类型：这条路径发出去的东西一个字节都不动
  ignore(
    client.request(
      @moonhttp.Config::new("/text")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_str("{\"pre\":\"serialized\"}")
      .with_header("Content-Type", "application/json"),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(@utf8.decode_lossy(sent.body.unwrap()), "{\"pre\":\"serialized\"}")
  assert_eq(sent.headers.get("Content-Type"), Some("application/json"))
}

///|
/// urlencoded body：头补 `application/x-www-form-urlencoded`，正文是编码后的键值对；
/// 用户显式设的类型同样优先。
async test "urlencoded body sets its content type" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.request(
      @moonhttp.Config::new("/login")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_urlencoded({ "user": "alice", "password": "s3cret" }),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(
    sent.headers.get("Content-Type"),
    Some("application/x-www-form-urlencoded"),
  )
  assert_eq(
    @utf8.decode_lossy(sent.body.unwrap()),
    "user=alice&password=s3cret",
  )
  // 同一条路径上用户显式设的类型优先（值里多带一个 charset 也照原样发）
  ignore(
    client.request(
      @moonhttp.Config::new("/login")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_urlencoded({ "a": "1" })
      .with_header(
        "Content-Type", "application/x-www-form-urlencoded;charset=utf-8",
      ),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("Content-Type"),
    Some("application/x-www-form-urlencoded;charset=utf-8"),
  )
}

///|
/// 表单 body 走 `multipart/form-data`：头里声明的 boundary 与正文里的分隔符
/// 是同一个，文本项与文件项都在（字节级的精确断言在 `config/body_test.mbt`）。
async test "form body goes out as multipart" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let form = @moonhttp.FormData::new()
    .append_text("title", "假期")
    .append_file("avatar", "a.png", b"\x89PNG", content_type="image/png")
  ignore(
    client.request(
      @moonhttp.Config::new("/upload")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_form(form),
    ),
  )
  let sent = mock.last_request().unwrap()
  let content_type = sent.headers.get("Content-Type").unwrap()
  assert_true(
    content_type.contains("multipart/form-data; boundary=----moonhttp-"),
  )
  // boundary 从头里取出来，正文必须严格按它分段，并以结束分隔符收尾
  let boundary = content_type.after("boundary=").unwrap().to_owned()
  let body = @utf8.decode_lossy(sent.body.unwrap())
  assert_true(
    body.contains(
      "--" +
      boundary +
      "\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\n假期\r\n",
    ),
  )
  assert_true(
    body.contains(
      "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n",
    ),
  )
  assert_true(body.contains("--" + boundary + "--\r\n"))
}

///|
/// 表单的 `Content-Type` 同样是「补默认值」：用户显式写了就一个字节都不改。
///
/// 代价是头与正文可能对不上（正文用的仍是自动生成的 boundary）——
/// 这是调用方自己钉死类型时必须承担的，库不做「帮你改头」这种事。
async test "user content type wins over the form default" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.request(
      @moonhttp.Config::new("/upload")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_form(@moonhttp.FormData::new().append_text("a", "1"))
      .with_header("Content-Type", "multipart/form-data; boundary=mine"),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(
    sent.headers.get("Content-Type"),
    Some("multipart/form-data; boundary=mine"),
  )
  // 正文仍按自己生成的 boundary 编码
  let body = @utf8.decode_lossy(sent.body.unwrap())
  assert_false(body.contains("boundary=mine"))
  assert_true(body.contains("----moonhttp-"))
}

///|
/// auth 配置生成 Basic 认证头，且不覆盖用户自己写的 Authorization。
async test "auth produces basic authorization header" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.request(
      @moonhttp.Config::new("/private").with_auth("alice", "s3cret"),
    ),
  )
  // base64("alice:s3cret")
  assert_eq(
    mock.last_request().unwrap().headers.get("Authorization"),
    Some("Basic YWxpY2U6czNjcmV0"),
  )
  ignore(
    client.request(
      @moonhttp.Config::new("/private")
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
/// 响应体的三种读法摆在方法上：`text()` 是原文、`bytes()` 是精确字节、
/// `json()` 才解析——读法由调用方选，库不猜内容类型。
async test "response body is read through explicit methods" {
  let (client, _) = client_with(raw_response(200, "OK", "{\"a\": 1}"))
  let response = client.request(@moonhttp.Config::new("/x"))
  assert_eq(response.text(), "{\"a\": 1}")
  assert_eq(response.bytes(), b"{\"a\": 1}")
  // 要对象就调 json()：它内部走的就是 text()，再交给 @json.parse
  assert_eq(response.json(), { "a": 1 })
}

///|
/// 不是合法 JSON 的正文照样原样交给调用方：`text()` 不解码也不报错，
/// `json()` 才抛 `@json.ParseError`——解析失败由调用方按自己的语境处理。
async test "a non json body is handed over as is" {
  let (client, _) = client_with(raw_response(200, "OK", "not json at all"))
  let response = client.request(@moonhttp.Config::new("/x"))
  assert_eq(response.text(), "not json at all")
  let raised = try {
    ignore(response.json())
    false
  } catch {
    // 抛的是 @json 的解析错误（带出错位置），不是 HttpError
    _ => true
  }
  assert_true(raised)
}

///|
/// 绝对地址默认直连；关掉 allow_absolute_urls 后会被拼到 base_url 后面。
async test "allow absolute urls can be turned off" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @moonhttp.Config::default().with_base_url("https://api.example.com"),
  )
  ignore(api.request(@moonhttp.Config::new("https://other.example.com/x")))
  assert_eq(mock.last_request().unwrap().url, "https://other.example.com/x")
  ignore(
    api.request(
      @moonhttp.Config::new("https://other.example.com/x").with_allow_absolute_urls(
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
/// `content_length` 是原始字节数而不是字符数：中文在 UTF-8 下占 3 字节。
async test "response content length counts bytes" {
  let (client, _) = client_with(raw_response(200, "OK", "中文"))
  let response = client.request(@moonhttp.Config::new("/x"))
  assert_eq(response.content_length(), 6)
  assert_eq(response.bytes().length(), 6)
  assert_eq(response.text(), "中文")
}
