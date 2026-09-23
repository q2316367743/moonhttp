// 本包的共享测试工具，以及实例创建 / 派生相关的用例。
// MoonBit 里同一包的所有 *_test.mbt 共用一个作用域，
// 所以这里的 raw_response / client_with 也被其它测试文件复用。

///|
/// 造一份带指定状态码与响应体的原始响应。
fn raw_response(
  status : Int,
  status_text : String,
  body : String,
) -> @transport.RawResponse {
  {
    status,
    status_text,
    headers: @transport.Headers::new().set("Content-Type", "application/json"),
    body: @utf8.encode(body),
  }
}

///|
/// 造一个「始终返回该响应」的实例，并把 Mock 传输层一起返回，便于断言收到的请求。
fn client_with(
  response : @transport.RawResponse,
) -> (@easy-http-client.Client, @transport.MockTransport) {
  let mock = @transport.MockTransport::new(response)
  let transport : &@transport.Transport = mock
  (@easy-http-client.Client::new(transport~), mock)
}

///|
/// `Client::create` 派生出的实例继承父实例默认值，并且是独立的——
/// 派生不会改动父实例。
async test "client create inherits defaults without mutating the parent" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let parent = client.create(
    @easy-http-client.Config::default()
    .with_base_url("https://api.example.com")
    .with_timeout(1000),
  )
  let child = parent.create(
    @easy-http-client.Config::default().with_timeout(2000),
  )
  assert_eq(child.defaults().base_url, Some("https://api.example.com"))
  assert_eq(child.defaults().timeout, Some(2000))
  // 父实例不受影响
  assert_eq(parent.defaults().timeout, Some(1000))
  // 派生出的实例确实带着继承来的默认值发请求
  ignore(child.request(@easy-http-client.Config::new("/users")))
  let sent = mock.last_request().unwrap()
  assert_eq(sent.url, "https://api.example.com/users")
  assert_eq(sent.timeout, Some(2000))
}

///|
/// 实例级别的默认请求方法会被继承；请求级方法优先。
async test "instance default method is inherited" {
  let (client, mock) = client_with(raw_response(200, "OK", "{}"))
  let api = client.create(
    @easy-http-client.Config::default().with_method(
      @easy-http-client.Method::Put,
    ),
  )
  ignore(api.request(@easy-http-client.Config::new("/a")))
  assert_eq(
    mock.last_request().unwrap().http_method,
    @easy-http-client.Method::Put,
  )
  ignore(
    api.request(
      @easy-http-client.Config::new("/a").with_method(
        @easy-http-client.Method::Patch,
      ),
    ),
  )
  assert_eq(
    mock.last_request().unwrap().http_method,
    @easy-http-client.Method::Patch,
  )
}

///|
/// `create()` 创建的是「内置默认值 + 用户配置」，因此不必显式配置
/// 就能拿到 axios 默认的 `Accept` 头。
async test "builtin defaults are applied by create" {
  let mock = @transport.MockTransport::new(raw_response(200, "OK", "{}"))
  let transport : &@transport.Transport = mock
  let client = @easy-http-client.Client::new(transport~)
  ignore(client.request(@easy-http-client.Config::new("/x")))
  assert_eq(
    mock.last_request().unwrap().headers.get("Accept"),
    Some("application/json, text/plain, */*"),
  )
}

///|
/// 公开工厂 `create(config=...)` 的语义：用户配置叠加在内置默认值之上。
/// 这里只检查默认值、不发请求，所以不需要 Mock 传输层。
test "create factory merges builtin defaults with user config" {
  let client = @easy-http-client.create(
    @easy-http-client.Config::default()
    .with_base_url("https://api.example.com")
    .with_timeout(1000),
  )
  let defaults = client.defaults()
  assert_eq(defaults.base_url, Some("https://api.example.com"))
  assert_eq(defaults.timeout, Some(1000))
  // 用户没设置的项来自内置默认值
  assert_eq(defaults.allow_absolute_urls, Some(true))
  assert_eq(
    defaults.common_headers.unwrap().get("Accept"),
    Some("application/json, text/plain, */*"),
  )
}

///|
/// `default_client()` 用内置默认值 + 真实传输层构造；不发请求时是安全的。
test "default client uses builtin defaults" {
  let client = @easy-http-client.default_client()
  assert_eq(client.defaults().timeout, Some(0))
  assert_eq(client.defaults().base_url, None)
}
