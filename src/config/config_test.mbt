///|
/// `Config::default()` 是「什么都没提供」——所有字段都是 None。
/// 这一点必须成立：合并时靠 None 判断「这一项没被设置」，从而决定是否回退默认值。
test "default config has every field unset" {
  let config = @config.Config::default()
  assert_eq(config.url, None)
  assert_eq(config.http_method, None)
  assert_eq(config.base_url, None)
  assert_eq(config.timeout, None)
  assert_eq(config.response_encoding, None)
  assert_eq(config.params, None)
  assert_eq(config.data, None)
  assert_eq(config.headers, None)
  assert_eq(config.common_headers, None)
  assert_eq(config.method_headers, None)
  assert_eq(config.allow_absolute_urls, None)
  assert_true(config.validate_status is None)
}

///|
/// 构建器链式返回新配置，字段按预期落位。
test "builders set fields and chain" {
  let config = @config.Config::default()
    .with_base_url("https://api.example.com")
    .with_url("/users")
    .with_method(@config.Method::Post)
    .with_timeout(5000)
    .with_response_encoding(@config.ResponseEncoding::Latin1)
    .with_params({ "page": 1 })
    .with_data({ "name": "moonbit" })
  assert_eq(config.base_url, Some("https://api.example.com"))
  assert_eq(config.url, Some("/users"))
  assert_eq(config.http_method, Some(@config.Method::Post))
  assert_eq(config.timeout, Some(5000))
  assert_eq(config.response_encoding, Some(@config.ResponseEncoding::Latin1))
  assert_eq(config.params, Some({ "page": 1 }))
  assert_eq(config.data, Some({ "name": "moonbit" }))
}

///|
/// 构建器不可变：派生出的配置不影响来源，这是「模板配置 + 逐个变体」用法的基础。
test "builders do not mutate the source config" {
  let template = @config.Config::default().with_base_url(
    "https://api.example.com",
  )
  let _ = template.with_url("/a")
  let _ = template.with_header("Accept", "text/plain")
  assert_eq(template.url, None)
  assert_eq(template.headers, None)
}

///|
/// 记录字面量展开（`{ ..Config::default(), field: ... }`）是「不走构建器」的写法，
/// 两种写法必须等价，否则说明有字段没按 Option 语义设计。
test "record spread is equivalent to builders" {
  let config : @config.Config = {
    ..@config.Config::default(),
    url: Some("/users"),
    http_method: Some(@config.Method::Get),
  }
  assert_eq(config.url, Some("/users"))
  assert_eq(config.http_method, Some(@config.Method::Get))
  assert_eq(config.base_url, None)
}

///|
/// `with_header` 累加多条头，同名时后者覆盖前者（大小写不敏感）。
test "with_header accumulates and overwrites" {
  let config = @config.Config::default()
    .with_header("Accept", "application/json")
    .with_header("X-Trace", "1")
    .with_header("accept", "text/plain")
  let headers = config.headers.unwrap()
  assert_eq(headers.length(), 2)
  assert_eq(headers.get("Accept"), Some("text/plain"))
  assert_eq(headers.get("x-trace"), Some("1"))
}

///|
/// 按方法分层的头分别存桶，互不干扰；且不修改来源配置的桶。
test "with_method_header keeps per-method buckets separate" {
  let template = @config.Config::default()
  let config = template
    .with_method_header(@config.Method::Get, "X-Only-Get", "1")
    .with_method_header(@config.Method::Post, "X-Only-Post", "1")
    .with_method_header(@config.Method::Get, "X-Only-Get", "2")
  let buckets = config.method_headers.unwrap()
  assert_eq(
    buckets.get(@config.Method::Get).unwrap().get("X-Only-Get"),
    Some("2"),
  )
  assert_eq(
    buckets.get(@config.Method::Post).unwrap().get("X-Only-Post"),
    Some("1"),
  )
  assert_eq(buckets.get(@config.Method::Get).unwrap().length(), 1)
  // 来源配置没有被写入，仍然是「没有桶」。
  assert_eq(template.method_headers, None)
}

///|
/// 内置默认值要覆盖 axios 的 timeout=0、Accept 头与 2xx 校验规则。
test "builtin defaults mirror axios" {
  let config = @config.defaults()
  assert_eq(config.timeout, Some(0))
  // axios 的 responseEncoding 默认值是 'utf8'，这里显式落在默认值里
  assert_eq(config.response_encoding, Some(@config.ResponseEncoding::Utf8))
  assert_eq(config.allow_absolute_urls, Some(true))
  assert_eq(
    config.common_headers.unwrap().get("Accept"),
    Some("application/json, text/plain, */*"),
  )
  let validate_status = config.validate_status.unwrap()
  assert_true(validate_status(200))
  assert_true(validate_status(204))
  assert_true(validate_status(299))
  // 3xx 与 4xx/5xx 都算失败：axios 的默认规则只看 2xx 区间。
  assert_false(validate_status(301))
  assert_false(validate_status(404))
  assert_false(validate_status(500))
}

///|
/// 方法名解析大小写不敏感，未知方法返回 None 而不是抛错。
test "method parse is case insensitive" {
  assert_eq(@config.Method::parse("GET"), Some(@config.Method::Get))
  assert_eq(@config.Method::parse("get"), Some(@config.Method::Get))
  assert_eq(@config.Method::parse("Delete"), Some(@config.Method::Delete))
  assert_eq(@config.Method::parse("patch"), Some(@config.Method::Patch))
  assert_eq(@config.Method::parse("BREW"), None)
}

///|
/// 方法名的 wire 形式是大写。
test "method wire name is upper case" {
  assert_eq(@config.Method::Get.to_string(), "GET")
  assert_eq(@config.Method::Options.to_string(), "OPTIONS")
  assert_eq(@config.Method::to_string(@config.Method::Put), "PUT")
}

///|
/// 配置的字符串渲染只列出被提供的字段，未提供的字段不出现（减少噪音）。
test "config to_string lists only provided fields" {
  let config = @config.Config::default()
    .with_base_url("https://api.example.com")
    .with_timeout(3000)
  assert_eq(
    config.to_string(),
    "Config { base_url: https://api.example.com, timeout: 3000 }",
  )
  assert_eq(@config.Config::default().to_string(), "Config { }")
}

///|
/// 认证信息里的密码必须脱敏，避免配置整体进日志时泄漏凭据。
test "auth rendering redacts password" {
  let auth = @config.Auth::{
    username: Some("alice"),
    password: Some("s3cret"),
  }
  let rendered = auth.to_string()
  assert_true(rendered.contains("alice"))
  assert_false(rendered.contains("s3cret"))
  assert_true(rendered.contains("<redacted>"))
}

///|
/// ResponseEncoding 的渲染值对应 axios 里 responseEncoding 的取值风格。
test "response encoding renders axios style values" {
  assert_eq(@config.ResponseEncoding::Utf8.to_string(), "utf-8")
  assert_eq(@config.ResponseEncoding::Latin1.to_string(), "latin1")
  assert_eq(@config.ResponseEncoding::Ascii.to_string(), "ascii")
  assert_eq(@config.ResponseEncoding::Utf16le.to_string(), "utf-16le")
}

///|
/// with_headers 是整体替换请求级头，而不是在已有基础上追加。
test "with_headers replaces the whole flat layer" {
  let config = @config.Config::default()
    .with_header("Accept", "a")
    .with_headers(@config.Headers::new().set("X-Only", "1"))
  let headers = config.headers.unwrap()
  assert_eq(headers.length(), 1)
  assert_eq(headers.get("X-Only"), Some("1"))
  assert_eq(headers.get("Accept"), None)
}

///|
/// common 层已有头时继续追加不会丢掉已有的。
test "with_common_header appends to the existing layer" {
  let config = @config.Config::default()
    .with_common_header("Accept", "a")
    .with_common_header("X-Trace", "1")
  let headers = config.common_headers.unwrap()
  assert_eq(headers.length(), 2)
  assert_eq(headers.get("Accept"), Some("a"))
}

///|
/// 渲染覆盖全部字段：每个已提供的字段都要出现（这是排查配置问题的唯一入口）。
test "config rendering covers every provided field" {
  let config = @config.Config::default()
    .with_url("/users")
    .with_method(@config.Method::Post)
    .with_base_url("https://api.example.com")
    .with_timeout(1000)
    .with_response_encoding(@config.ResponseEncoding::Utf16le)
    .with_params({ "page": 1 })
    .with_data({ "name": "moon" })
    .with_auth("alice", "secret")
    .with_header("X-Trace", "1")
    .with_common_header("Accept", "application/json")
    .with_method_header(@config.Method::Get, "X-Get", "1")
    .with_validate_status(fn(status) { status >= 200 && status < 300 })
    .with_allow_absolute_urls(true)
  let rendered = config.to_string()
  for
    expected in [
      "url: /users", "method: POST", "base_url: https://api.example.com", "timeout: 1000",
      "response_encoding: utf-16le", "params: ", "data: ", "auth: Auth { username: alice, password: <redacted> }",
      "headers: X-Trace: 1", "common_headers: Accept: application/json", "method_headers: GET -> X-Get: 1",
      "validate_status: <fn>", "allow_absolute_urls: true",
    ] {
    assert_true(rendered.contains(expected))
  }
  // 字符串插值走 Show，与 to_string 同格式
  assert_eq("\{config}", rendered)
}

///|
/// Auth 只给一半凭据时，渲染里只出现给了的那一半。
test "auth rendering handles partial credentials" {
  let only_username = @config.Auth::{ username: Some("alice"), password: None, }
  assert_eq(only_username.to_string(), "Auth { username: alice }")
  let only_password = @config.Auth::{ username: None, password: Some("s"), }
  assert_eq(only_password.to_string(), "Auth { password: <redacted> }")
  assert_eq(@config.Auth::default().to_string(), "Auth { }")
}

///|
/// 多个方法桶之间用 `; ` 分隔，且按插入顺序排列。
test "config rendering separates multiple method buckets" {
  let config = @config.Config::default()
    .with_method_header(@config.Method::Get, "X-Get", "1")
    .with_method_header(@config.Method::Post, "X-Post", "2")
  assert_true(
    config
    .to_string()
    .contains("method_headers: GET -> X-Get: 1; POST -> X-Post: 2"),
  )
}

///|
/// Config 的 Debug 渲染与 Show 同格式。
test "config debug rendering matches show" {
  debug_inspect(
    @config.Config::default().with_url("/users"),
    content="\"Config { url: /users }\"",
  )
}

///|
/// `Config::new(url)` 等价于 `Config::default().with_url(url)`：
/// 只设置 url 这一个字段，其余保持「未提供」。
test "config new only sets the url" {
  let config = @config.Config::new("/users")
  assert_eq(config.url, Some("/users"))
  assert_eq(config.base_url, None)
  assert_eq(config.http_method, None)
  assert_eq(config.timeout, None)
  assert_eq(
    config.to_string(),
    @config.Config::default().with_url("/users").to_string(),
  )
}
