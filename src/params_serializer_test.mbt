// `params_serializer` 的端到端用例：它落在 `build_prepared_request` 里，
// 所以「发出去的 URL 长什么样」是唯一的验收面。
// 字段本身的落位、合并与渲染见 src/config/params_serializer_test.mbt，
// 拼接规则的边界见 src/url/url_test.mbt。

///|
/// 实例级的序列化器对该实例的所有请求生效——这是它的主要用法：
/// 后端的 query 约定是固定的（例如列表要重复平键 `tags=a&tags=b`），
/// 在实例上设置一次就够，不必每个请求重复写。
async test "instance level params serializer applies to every request" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @moonhttp.Config::default().with_params_serializer(fn(_params) {
      "tags=a&tags=b"
    }),
  )
  ignore(
    api.request(
      @moonhttp.Config::new("/search").with_params({ "tags": ["a", "b"] }),
    ),
  )
  // 内置规则会写成 tags%5B%5D=a&tags%5B%5D=b，自定义规则整体替换了它
  assert_eq(mock.last_request().unwrap().url, "/search?tags=a&tags=b")
}

///|
/// 请求级提供时**整体替换**实例默认值（对齐 axios 的 `defaultToConfig2`）：
/// 两个序列化器不会被串成一条链，实例级那条完全不出现在 URL 里。
async test "request level params serializer replaces the instance default" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @moonhttp.Config::default().with_params_serializer(fn(_params) {
      "from=instance"
    }),
  )
  ignore(
    api.request(
      @moonhttp.Config::new("/search")
      .with_params({ "a": 1 })
      .with_params_serializer(fn(_params) { "from=request" }),
    ),
  )
  assert_eq(mock.last_request().unwrap().url, "/search?from=request")
}

///|
/// 序列化器只管 URL 的 query：`with_data_from_urlencoded` 的请求体仍走内置规则
/// （axios 里请求体走的是另一个内部选项 `formSerializer`，两者本就分开）。
/// 同一个 `Json` 放 query 还是放 body，只有 query 那侧会被替换。
async test "params serializer does not touch the urlencoded body" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @moonhttp.Config::default().with_params_serializer(fn(_params) {
      "tags=a&tags=b"
    }),
  )
  ignore(
    api.request(
      @moonhttp.Config::new("/submit")
      .with_method(@moonhttp.Method::Post)
      .with_params({ "tags": ["a", "b"] })
      .with_data_from_urlencoded({ "tags": ["a", "b"] }),
    ),
  )
  let sent = mock.last_request().unwrap()
  assert_eq(sent.url, "/submit?tags=a&tags=b")
  assert_eq(sent.body, Some(b"tags%5B%5D=a&tags%5B%5D=b"))
}

///|
/// 拼请求这一层是三个入口共用的，所以流式入口同样生效
/// （与 `response_encoding` 只管 `request` 那一路不同）。
async test "params serializer also applies on the streaming entry" {
  let (client, mock) = client_with(raw_response(200, "OK", "chunk"))
  let stream = client.stream(
    @moonhttp.Config::new("/events")
    .with_params({ "tags": ["a", "b"] })
    .with_params_serializer(fn(_params) { "tags=a&tags=b" }),
  )
  stream.close()
  assert_eq(mock.last_request().unwrap().url, "/events?tags=a&tags=b")
}
