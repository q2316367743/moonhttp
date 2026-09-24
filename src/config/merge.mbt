// 配置合并契约（对应 axios `lib/core/mergeConfig.js`），契约细节见 docs/02-config-merge.md。
//
// 它曾经是独立的 `merge` 包，现在与 `Config` 同包：`Config.data` 是私有字段之后，
// 只有 config 包能构造 `Config`（跨包的记录字面量与记录展开都会被编译器拒绝，
// 报 `cannot use struct update syntax ... because it has private fields`），
// 而 `merge_config` 必须逐字段构造出一份新配置。
// 同包的额外好处是「字段 → 策略」的同步被编译器强制：往 `Config` 加字段而忘了
// 在这里选一档策略，是编译错误，不是静默漏合并。

///|
/// 策略 1：只取请求级（对应 axios `mergeConfig` 的 `valueFromConfig2`）。
///
/// `url` / `http_method` / `data` 用这个策略：默认值里就算有同名字段也会被丢弃。
/// 理由是这三项在语义上回答的是「这一次请求要做什么」，
/// 从实例默认值里继承一个 url 或 body 没有意义，
/// 而且很容易造成「配置里没写 url 却发出了上一次的请求」这类意外。
fn[T] value_from_request(base : T?, request : T?) -> T? {
  ignore(base)
  request
}

///|
/// 策略 2：请求级优先，否则回退默认值（对应 `defaultToConfig2`）。
///
/// 这是最符合直觉的一档：请求里没写的配置项就沿用实例默认值。
fn[T] prefer_request(base : T?, request : T?) -> T? {
  match request {
    Some(_) => request
    None => base
  }
}

///|
/// 策略 4：请求级「存在即生效」（对应 `mergeDirectKeys`）。
///
/// 在 axios 里这一档与策略 2 的差别是：它只看键「存不存在」，
/// 连显式的 `undefined`/`null` 也算存在，于是可以用它把默认的
/// `validateStatus` 整个关掉（传 `null` 即可）。
///
/// 本项目的字段是 `Option`，「存在」就等于 `Some`，所以实现与策略 2 同形。
/// 保留独立的名字是为了标明语义：想关掉状态码校验时，
/// 传一个恒真的函数（`with_validate_status(fn(_) { true })`），
/// 而不是删掉这个字段——删掉只会退回默认的 2xx 规则。
fn[T] request_overrides(base : T?, request : T?) -> T? {
  prefer_request(base, request)
}

///|
/// `Headers` 的深合并（axios 里唯一按大小写不敏感方式合并的字段）。
///
/// axios 的 `AxiosHeaders` 把 `Content-Type` 与 `content-type` 视为同一个键，
/// 本项目的 `Headers` 同样在存储时规范化键，所以直接交给 `Headers::merge`：
/// 请求级同名头覆盖默认值，默认值里请求级没提的头则保留下来。
///
/// 只有一侧存在时直接返回该侧，不做拷贝——`Headers` 的所有变更方法都返回新实例，
/// 共享引用不会被后续操作改坏（axios 在这里要 clone，是因为它的普通对象是可变的）。
fn merge_headers(base : Headers?, request : Headers?) -> Headers? {
  match (base, request) {
    (None, None) => None
    (Some(base), None) => Some(base)
    (None, Some(request)) => Some(request)
    (Some(base), Some(request)) => Some(base.merge(request))
  }
}

///|
/// `Auth` 的逐字段深合并，对应 axios 对 `{username, password}` 这种普通对象的递归合并。
///
/// 「默认值只给 username、请求只给 password」能拼出完整凭据，
/// 而不是请求级的对象整体替换掉默认值。
fn merge_auth(base : Auth?, request : Auth?) -> Auth? {
  match (base, request) {
    (None, None) => None
    (Some(base), None) => Some(base)
    (None, Some(request)) => Some(request)
    (Some(base), Some(request)) =>
      Some({
        username: prefer_request(base.username, request.username),
        password: prefer_request(base.password, request.password),
      })
  }
}

///|
/// 按方法分层的默认头（`common_headers` 之外的第二层）深合并。
///
/// 合并发生在「桶」的粒度上：请求级只想改 GET 的头时，
/// 其它方法（POST/PUT…）的桶必须原样保留，因此不能整体替换 Map。
fn merge_method_headers(
  base : Map[Method, Headers]?,
  request : Map[Method, Headers]?,
) -> Map[Method, Headers]? {
  match (base, request) {
    (None, None) => None
    (Some(base), None) => Some(base)
    (None, Some(request)) => Some(request)
    (Some(base), Some(request)) => {
      // 先 copy 再改：base 可能被别的 Config 引用着，就地修改会破坏值语义。
      let merged = base.copy()
      for meth, headers in request {
        let bucket = match merged.get(meth) {
          Some(existing) => existing.merge(headers)
          None => headers
        }
        merged[meth] = bucket
      }
      Some(merged)
    }
  }
}

///|
/// 合并两份配置，返回新配置。`base` 通常是实例的默认值，`request` 是本次请求的配置。
///
/// 这是 axios `mergeConfig(config1, config2)` 的对应物。axios 用一张
/// 「字段 → 合并函数」的表来遍历所有键，MoonBit 没有运行时反射，
/// 所以这里改成逐字段显式调用对应策略——好处是每个字段用哪一档策略
/// 在源码里一眼可见，不需要再去查那张表。
///
/// 策略分配与 axios 保持一致：
/// - 只取请求级：url / http_method / data
/// - 请求级优先、否则默认：base_url / timeout / response_encoding / allow_absolute_urls
/// - 深合并：params / auth / headers / common_headers / method_headers
/// - 存在即生效：validate_status
///
/// 注意 `allow_absolute_urls` 这类标量在 axios 里走的是默认策略
/// `mergeDeepProperties`，而「深合并」作用在标量上退化成「请求级有就用请求级」，
/// 结果与「请求级优先、否则默认」相同。
///
/// `None` 一律表示「未提供」，永远是回退而不是覆盖；
/// 数组（例如 `params` 里的数组）是整体替换而不是拼接，
/// 因为 axios 的 `utils.merge` 只对普通对象递归。
pub fn merge_config(base : Config, request : Config) -> Config {
  {
    // 策略 1：只取请求级
    url: value_from_request(base.url, request.url),
    http_method: value_from_request(base.http_method, request.http_method),
    data: value_from_request(base.data, request.data),
    // 策略 2：请求级优先，否则回退默认值
    base_url: prefer_request(base.base_url, request.base_url),
    timeout: prefer_request(base.timeout, request.timeout),
    response_encoding: prefer_request(
      base.response_encoding,
      request.response_encoding,
    ),
    allow_absolute_urls: prefer_request(
      base.allow_absolute_urls,
      request.allow_absolute_urls,
    ),
    // 策略 3：深合并
    params: merge_json_option(base.params, request.params),
    auth: merge_auth(base.auth, request.auth),
    headers: merge_headers(base.headers, request.headers),
    common_headers: merge_headers(base.common_headers, request.common_headers),
    method_headers: merge_method_headers(
      base.method_headers,
      request.method_headers,
    ),
    // 策略 4：请求级存在即生效
    validate_status: request_overrides(
      base.validate_status,
      request.validate_status,
    ),
  }
}

///|
/// 把三层头按 axios 的优先级拍平成一份：`common` < 按方法 < 请求级平铺。
///
/// axios 在 `_request` 里做的是
/// `AxiosHeaders.concat(headers.common, headers[config.method], headers)`
/// 然后把 `common` / 各方法名从对象上删掉；`concat` 的语义是后者覆盖前者，
/// 所以这里从低到高依次 `merge` 就能得到同样的结果。
/// `flatten_headers(common, None, flat, Get)` 这种缺层的情况直接跳过即可，
/// 空层不参与合并不会改变结果。
pub fn flatten_headers(
  common : Headers?,
  method_headers : Map[Method, Headers]?,
  flat : Headers?,
  meth : Method,
) -> Headers {
  let mut result = Headers::new()
  match common {
    Some(common) => result = result.merge(common)
    None => ()
  }
  match method_headers {
    Some(buckets) =>
      match buckets.get(meth) {
        Some(bucket) => result = result.merge(bucket)
        None => ()
      }
    None => ()
  }
  match flat {
    Some(flat) => result = result.merge(flat)
    None => ()
  }
  result
}
