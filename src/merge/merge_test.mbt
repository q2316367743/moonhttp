///|
/// 策略 1 的三个字段：`url` / `http_method` / `data` 只认请求级。
///
/// 默认值里写了 url 也不会被继承——否则「这次忘了写 url」会静默地
/// 重放上一次地址，是最危险的一种「有默认值」。
test "url method and data come only from the request" {
  let base = @merge.Config::default()
    .with_url("/default-path")
    .with_method(@merge.Method::Delete)
    .with_data({ "from": "base" })
  let request = @merge.Config::default()
  let merged = @merge.merge_config(base, request)
  assert_eq(merged.url, None)
  assert_eq(merged.http_method, None)
  assert_eq(merged.data, None)
  // 请求级显式提供时正常生效
  let merged = @merge.merge_config(
    base,
    @merge.Config::default()
    .with_url("/users")
    .with_method(@merge.Method::Post)
    .with_data({ "from": "request" }),
  )
  assert_eq(merged.url, Some("/users"))
  assert_eq(merged.http_method, Some(@merge.Method::Post))
  assert_eq(merged.data, Some({ "from": "request" }))
}

///|
/// 策略 2 的三个字段：请求级优先，缺省则回退默认值。
test "base url timeout and response type fall back to defaults" {
  let base = @merge.Config::default()
    .with_base_url("https://api.example.com")
    .with_timeout(1000)
    .with_response_type(@merge.ResponseType::Text)
  // 请求级什么都设：全部回退
  let inherited = @merge.merge_config(base, @merge.Config::default())
  assert_eq(inherited.base_url, Some("https://api.example.com"))
  assert_eq(inherited.timeout, Some(1000))
  assert_eq(inherited.response_type, Some(@merge.ResponseType::Text))
  // 请求级覆盖：以请求级为准
  let overridden = @merge.merge_config(
    base,
    @merge.Config::default()
    .with_base_url("https://other.example.com")
    .with_timeout(2000)
    .with_response_type(@merge.ResponseType::Json),
  )
  assert_eq(overridden.base_url, Some("https://other.example.com"))
  assert_eq(overridden.timeout, Some(2000))
  assert_eq(overridden.response_type, Some(@merge.ResponseType::Json))
}

///|
/// `headers` 是深合并而不是整体替换：请求级覆盖同名的，
/// 默认值里请求级没提的头保留下来，且比较时忽略大小写。
test "headers are deep merged case insensitively" {
  let base = @merge.Config::default()
    .with_header("Accept", "application/json")
    .with_header("X-From-Base", "base")
  let request = @merge.Config::default()
    .with_header("accept", "text/plain")
    .with_header("X-From-Request", "request")
  let merged = @merge.merge_config(base, request)
  let headers = merged.headers.unwrap()
  assert_eq(headers.length(), 3)
  assert_eq(headers.get("Accept"), Some("text/plain"))
  assert_eq(headers.get("X-From-Base"), Some("base"))
  assert_eq(headers.get("X-From-Request"), Some("request"))
}

///|
/// `common_headers` 与 `method_headers` 同样深合并；
/// 按方法分桶时，请求级只改一个方法不能把别的桶丢掉。
test "layered header buckets merge per method" {
  let base = @merge.Config::default()
    .with_common_header("Accept", "application/json")
    .with_method_header(@merge.Method::Get, "X-Get", "base")
    .with_method_header(@merge.Method::Post, "X-Post", "base")
  let request = @merge.Config::default()
    .with_common_header("X-Trace", "1")
    .with_method_header(@merge.Method::Get, "X-Get", "request")
  let merged = @merge.merge_config(base, request)
  let common = merged.common_headers.unwrap()
  assert_eq(common.get("Accept"), Some("application/json"))
  assert_eq(common.get("X-Trace"), Some("1"))
  let buckets = merged.method_headers.unwrap()
  assert_eq(
    buckets.get(@merge.Method::Get).unwrap().get("X-Get"),
    Some("request"),
  )
  // POST 的桶必须原样保留：不能因为请求级没提 POST 就被清空
  assert_eq(
    buckets.get(@merge.Method::Post).unwrap().get("X-Post"),
    Some("base"),
  )
}

///|
/// `params` 逐键深合并：请求级只补/改自己提到的键。
test "params are deep merged key by key" {
  let base = @merge.Config::default().with_params({ "page": 1, "size": 20 })
  let request = @merge.Config::default().with_params({ "page": 2 })
  let merged = @merge.merge_config(base, request)
  assert_eq(merged.params, Some({ "page": 2, "size": 20 }))
}

///|
/// 数组整体替换而不是拼接：这是 axios `utils.merge` 的明确行为，
/// 只在请求级出现的数组换掉默认值里的整个数组。
test "params arrays are replaced not concatenated" {
  let base = @merge.Config::default().with_params({ "tags": ["a", "b"] })
  let request = @merge.Config::default().with_params({ "tags": ["c"] })
  let merged = @merge.merge_config(base, request)
  assert_eq(merged.params, Some({ "tags": ["c"] }))
}

///|
/// 嵌套对象递归合并：默认值里的兄弟键不会因为请求级只改了一个子键而消失。
test "params nested objects merge recursively" {
  let base = @merge.Config::default().with_params({
    "filter": { "status": 1, "owner": "me" },
  })
  let request = @merge.Config::default().with_params({
    "filter": { "status": 2 },
  })
  let merged = @merge.merge_config(base, request)
  assert_eq(merged.params, Some({ "filter": { "status": 2, "owner": "me" } }))
}

///|
/// `auth` 逐字段深合并：默认值给用户名、请求给密码，能拼出完整凭据。
test "auth merges field by field" {
  let base = @merge.Config::default().with_auth("alice", "old-secret")
  let request : @merge.Config = {
    ..@merge.Config::default(),
    // 只提供 password，username 通过 Auth 的字段级深合并从默认值继承
    auth: Some({ ..@merge.Auth::default(), password: Some("new-secret"), }),
  }
  let merged = @merge.merge_config(base, request)
  let auth = merged.auth.unwrap()
  assert_eq(auth.username, Some("alice"))
  assert_eq(auth.password, Some("new-secret"))
}

///|
/// `validate_status` 存在即生效：请求级提供了就完全接管，
/// 没提供则沿用默认值（内置默认值是 2xx 规则）。
test "validate_status is taken wholesale from the request" {
  let base = @config.defaults()
  let inherited = @merge.merge_config(base, @merge.Config::default())
  let inherited_rule = inherited.validate_status.unwrap()
  assert_true(inherited_rule(200))
  assert_false(inherited_rule(404))
  // 请求级用恒真函数把校验整个关掉——这就是本项目「传 null 关闭校验」的等价写法
  let permissive = @merge.merge_config(
    base,
    @merge.Config::default().with_validate_status(fn(_status) { true }),
  )
  let permissive_rule = permissive.validate_status.unwrap()
  assert_true(permissive_rule(404))
  assert_true(permissive_rule(500))
}

///|
/// `allow_absolute_urls` 走的是 axios 的默认策略（深合并），
/// 对布尔这种标量退化成「请求级有就用请求级」。
test "allow_absolute_urls prefers the request value" {
  let base = @config.defaults()
  assert_eq(
    @merge.merge_config(base, @merge.Config::default()).allow_absolute_urls,
    Some(true),
  )
  assert_eq(
    @merge.merge_config(
      base,
      @merge.Config::default().with_allow_absolute_urls(false),
    ).allow_absolute_urls,
    Some(false),
  )
}

///|
/// 合并结果不与输入共享可变状态：改合并结果不应影响请求级配置。
test "merge result does not alias the inputs" {
  let base = @merge.Config::default().with_header("Accept", "application/json")
  let request = @merge.Config::default().with_header("X-Trace", "1")
  let merged = @merge.merge_config(base, request)
  let mutated = merged.with_header("Accept", "text/plain")
  assert_eq(mutated.headers.unwrap().get("Accept"), Some("text/plain"))
  // 两侧输入都保持原样
  assert_eq(base.headers.unwrap().get("Accept"), Some("application/json"))
  assert_eq(request.headers.unwrap().get("X-Trace"), Some("1"))
  assert_eq(merged.headers.unwrap().get("Accept"), Some("application/json"))
}

///|
/// 三层头的优先级：common 最低，按方法次之，请求级平铺最高。
test "flatten_headers applies common then method then flat" {
  let common = @merge.Headers::new().set("X-Layer", "common").set("Accept", "a")
  let buckets : Map[@merge.Method, @merge.Headers] = Map([])
  buckets[@merge.Method::Get] = @merge.Headers::new().set("X-Layer", "method")
  let flat = @merge.Headers::new().set("X-Layer", "flat")
  let headers = @merge.flatten_headers(
    Some(common),
    Some(buckets),
    Some(flat),
    @merge.Method::Get,
  )
  assert_eq(headers.get("X-Layer"), Some("flat"))
  // common 里独有的头保留
  assert_eq(headers.get("Accept"), Some("a"))

  // 去掉请求级平铺这一层，按方法层胜出
  let headers = @merge.flatten_headers(
    Some(common),
    Some(buckets),
    None,
    @merge.Method::Get,
  )
  assert_eq(headers.get("X-Layer"), Some("method"))

  // 方法不匹配时按方法层不参与
  let headers = @merge.flatten_headers(
    Some(common),
    Some(buckets),
    None,
    @merge.Method::Post,
  )
  assert_eq(headers.get("X-Layer"), Some("common"))
}

///|
/// 三层都可能缺失，任意组合都不能崩，且结果为空集合而不是 None。
test "flatten_headers tolerates missing layers" {
  let empty = @merge.flatten_headers(None, None, None, @merge.Method::Get)
  assert_true(empty.is_empty())
  let only_flat = @merge.flatten_headers(
    None,
    None,
    Some(@merge.Headers::new().set("X-Only", "1")),
    @merge.Method::Get,
  )
  assert_eq(only_flat.get("X-Only"), Some("1"))
}

///|
/// `merge_json` 的三个分支：对象递归、数组替换、标量覆盖。
test "merge_json branches" {
  assert_eq(
    @merge.merge_json({ "a": 1, "b": { "c": 2 } }, { "b": { "d": 3 } }),
    { "a": 1, "b": { "c": 2, "d": 3 } },
  )
  assert_eq(@merge.merge_json({ "a": [1, 2] }, { "a": [3] }), { "a": [3] })
  assert_eq(@merge.merge_json({ "a": 1 }, { "a": "text" }), { "a": "text" })
  assert_eq(@merge.merge_json(1, "text"), "text")
}

///|
/// 复合值只有一侧提供时结果就是那一侧，不需要两边都有值。
test "one sided compound values pass through" {
  let base_auth = @merge.merge_config(
    @merge.Config::default().with_auth("alice", "s"),
    @merge.Config::default(),
  )
  assert_eq(base_auth.auth.unwrap().username, Some("alice"))
  let request_auth = @merge.merge_config(
    @merge.Config::default(),
    @merge.Config::default().with_auth("bob", "t"),
  )
  assert_eq(request_auth.auth.unwrap().username, Some("bob"))
  let base_params = @merge.merge_config(
    @merge.Config::default().with_params({ "a": 1 }),
    @merge.Config::default(),
  )
  assert_eq(base_params.params, Some({ "a": 1 }))
  let request_buckets = @merge.merge_config(
    @merge.Config::default(),
    @merge.Config::default().with_method_header(
      @merge.Method::Get,
      "X-Get",
      "1",
    ),
  )
  assert_eq(
    request_buckets.method_headers
    .unwrap()
    .get(@merge.Method::Get)
    .unwrap()
    .get("X-Get"),
    Some("1"),
  )
}
