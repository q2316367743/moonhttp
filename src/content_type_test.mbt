// `Auto` 模式下响应体怎么解码，由 `Content-Type` 声明决定。
//
// 为什么要这道门槛：`123`、`true`、`"x"` 这些**纯文本本身就是合法 JSON 文本**。
// 无脑尝试解析会把 `text/plain` 的响应变成数字或布尔值——这是最典型的一类
// 「服务端返回得没错、客户端解错了」。

///|
/// 造一份带指定 `Content-Type` 的响应；`content_type` 为 `None` 表示不带这个头。
fn typed_response(
  content_type : String?,
  body : String,
) -> @transport.RawResponse {
  let headers = match content_type {
    Some(value) => @transport.Headers::new().set("Content-Type", value)
    None => @transport.Headers::new()
  }
  {
    status: 200,
    status_text: "OK",
    headers,
    body: @transport.ResponseBody::from_bytes(@utf8.encode(body)),
  }
}

///|
/// 关键回归：声明了 `text/plain` 的纯文本不能被当成 JSON。
///
/// `123` 是合法 JSON 文本，所以这条用例能钉住「先看 Content-Type」这件事：
/// 少了这道门槛，`data` 会变成 `Json::Number(123)`。
async test "a plain text body is not decoded as json" {
  let (client, _) = client_with(typed_response(Some("text/plain"), "123"))
  let response = client.request(@moonhttp.Config::new("/x"))
  assert_eq(response.data, "123")
  assert_eq(response.text(), "123")
}

///|
/// 声明了 JSON 就解析成对象。
async test "a declared json body is decoded" {
  let (client, _) = client_with(
    typed_response(Some("application/json"), "{\"a\": 1}"),
  )
  assert_eq(client.request(@moonhttp.Config::new("/x")).data, { "a": 1 })
}

///|
/// 带结构化后缀的 `application/*+json` 也算 JSON
/// （`application/problem+json`、`application/vnd.api+json` 这类）。
async test "structured json suffixes are decoded" {
  let (client, _) = client_with(
    typed_response(Some("application/problem+json"), "{\"title\": \"boom\"}"),
  )
  assert_eq(client.request(@moonhttp.Config::new("/x")).data, {
    "title": "boom",
  })
}

///|
/// 媒体类型大小写不敏感，`;` 之后的参数（charset 等）不参与判定。
async test "content type is matched caselessly and ignores parameters" {
  let (client, _) = client_with(
    typed_response(Some("Application/JSON; charset=utf-8"), "{\"a\": 1}"),
  )
  assert_eq(client.request(@moonhttp.Config::new("/x")).data, { "a": 1 })
}

///|
/// 没有 `Content-Type` 时仍然尝试解析：很多服务端返回 JSON 却不带这个头，
/// 卡死它们得不偿失（保留 axios 的 forcedJSONParsing 行为）。
async test "a missing content type still tries json" {
  let (client, _) = client_with(typed_response(None, "{\"a\": 1}"))
  assert_eq(client.request(@moonhttp.Config::new("/x")).data, { "a": 1 })
}

///|
/// `Content-Type` 存在但值为空（或只有空白），等同于「没声明」——
/// 有些服务端确实会发一个空头。文档里「缺失或为空」这句就靠这条用例顶着。
async test "an empty content type counts as undeclared" {
  let (empty, _) = client_with(typed_response(Some(""), "{\"a\": 1}"))
  assert_eq(empty.request(@moonhttp.Config::new("/x")).data, { "a": 1 })
  let (blank, _) = client_with(typed_response(Some("  "), "\"text\""))
  assert_eq(blank.request(@moonhttp.Config::new("/x")).data, "text")
}

///|
/// 声明成别的类型（HTML / XML / 二进制……）就完全不解析。
async test "a non-json declaration is never decoded" {
  let (client, _) = client_with(
    typed_response(Some("text/html"), "<html>nope</html>"),
  )
  assert_eq(
    client.request(@moonhttp.Config::new("/x")).data,
    "<html>nope</html>",
  )
}

///|
/// `Json` 是真「强制」：`Content-Type` 管不到它。
async test "forced json decoding ignores the content type" {
  let (client, _) = client_with(typed_response(Some("text/html"), "{\"a\": 1}"))
  assert_eq(
    client.request(
      @moonhttp.Config::new("/x").with_response_type(
        @moonhttp.ResponseType::Json,
      ),
    ).data,
    { "a": 1 },
  )
}

///|
/// `Text` 是真「不解析」：声明了 JSON 也不解。
async test "text response type never decodes" {
  let (client, _) = client_with(
    typed_response(Some("application/json"), "{\"a\": 1}"),
  )
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_type(@moonhttp.ResponseType::Text),
  )
  assert_eq(response.data, "{\"a\": 1}")
}
