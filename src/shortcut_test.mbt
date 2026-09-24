// 快捷方法的用例：动词是否真的落到线上、`url` / 动词的优先级、以及实例默认值、
// 请求体、错误路径是不是照旧走 `request` 那条管线。
//
// 契约见 `src/shortcuts.mbt` 的文件头与 `docs/14-shortcut-methods.md`。

///|
/// 七个动词各自发出对应的 HTTP 方法；不传 `config` 时没有请求体（契约 3）。
async test "shortcuts send their own verbs" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let url = "https://api.example.com/a"
  ignore(client.get(url))
  assert_eq(mock.last_request().unwrap().http_method, @moonhttp.Method::Get)
  ignore(client.post(url))
  assert_eq(mock.last_request().unwrap().http_method, @moonhttp.Method::Post)
  ignore(client.put(url))
  assert_eq(mock.last_request().unwrap().http_method, @moonhttp.Method::Put)
  ignore(client.delete(url))
  let deleted = mock.last_request().unwrap()
  assert_eq(deleted.http_method, @moonhttp.Method::Delete)
  assert_eq(deleted.body, None)
  ignore(client.patch(url))
  assert_eq(mock.last_request().unwrap().http_method, @moonhttp.Method::Patch)
  ignore(client.head(url))
  assert_eq(mock.last_request().unwrap().http_method, @moonhttp.Method::Head)
  ignore(client.options(url))
  assert_eq(mock.last_request().unwrap().http_method, @moonhttp.Method::Options)
  // 七次调用就是七次发送，没有哪一次被合并或吞掉
  assert_eq(mock.request_count(), 7)
}

///|
/// 契约 1 与 2：`url` 位置参数赢过 `config.url`，动词赢过 `config` 里的
/// `with_method(...)`——`get` 永远是 GET，哪怕配置里写着 PATCH。
async test "shortcut url and verb win over config" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  ignore(
    client.get(
      "https://api.example.com/b",
      config=@moonhttp.Config::new("https://api.example.com/a").with_method(
        @moonhttp.Method::Patch,
      ),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(sent.url, "https://api.example.com/b")
  assert_eq(sent.http_method, @moonhttp.Method::Get)
}

///|
/// 实例默认值照旧生效：`base_url` 拼接、`params`、`timeout`、公共头与按方法头
/// （按快捷方法设下的动词匹配）都变现到最终发出的请求上。
async test "shortcuts keep instance defaults and request config" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @moonhttp.Config::default()
    .with_base_url("https://api.example.com")
    .with_timeout(1234)
    .with_common_header("Accept", "application/vnd.api+json")
    .with_method_header(@moonhttp.Method::Get, "X-Get-Only", "1"),
  )
  let response = api.get(
    "/users",
    config=@moonhttp.Config::default().with_params({ "page": 1 }),
  )
  // 响应侧与 request 一致：读全量、状态码已校验
  assert_eq(response.status, 200)
  assert_true(response.is_success())
  let sent = mock.last_request().unwrap()
  assert_eq(sent.url, "https://api.example.com/users?page=1")
  assert_eq(sent.http_method, @moonhttp.Method::Get)
  assert_eq(sent.timeout, Some(1234))
  assert_eq(sent.headers.get("Accept"), Some("application/vnd.api+json"))
  assert_eq(sent.headers.get("X-Get-Only"), Some("1"))
}

///|
/// 请求体由 `config` 给出：形态与自动补的 `Content-Type` 都和 `request` 一致。
/// 实例默认方法盖不掉显式动词，`config` 里的方法也盖不掉。
async test "shortcuts take body and verb from request config" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  // 实例默认方法设成 PUT，`get` 仍然发 GET
  let api = client.create(
    @moonhttp.Config::default().with_method(@moonhttp.Method::Put),
  )
  ignore(api.get("https://api.example.com/a"))
  assert_eq(mock.last_request().unwrap().http_method, @moonhttp.Method::Get)
  // 请求体走 config：JSON 体 + 自动补的 Content-Type
  ignore(
    api.post(
      "https://api.example.com/users",
      config=@moonhttp.Config::default().with_data_from_json({ "name": "moon" }),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(sent.http_method, @moonhttp.Method::Post)
  assert_eq(@utf8.decode_lossy(sent.body.unwrap()), "{\"name\":\"moon\"}")
  assert_eq(sent.headers.get("Content-Type"), Some("application/json"))
}

///|
/// 错误路径没有分叉：4xx 一样抛 `HttpError`、一样带着响应，错误码与
/// `client.request(...)` 发出同一个请求时相同。
async test "shortcuts share the error path" {
  let response = raw_response(404, "Not Found", "{\"error\": \"nope\"}")
  let (client, _mock) = client_with(response)
  let error = try {
    ignore(client.get("https://api.example.com/missing"))
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::BadRequest)
  assert_eq(error.response().unwrap().status, 404)
  assert_eq(error.response().unwrap().text(), "{\"error\": \"nope\"}")
}
