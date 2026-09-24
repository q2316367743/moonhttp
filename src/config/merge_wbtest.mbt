// 合并契约的白盒测试：直接测策略函数本身，以及那些**只能从包内构造**的配置。
//
// 「只能从包内构造」指 `Config.data` 私有：包外用不了记录字面量 / 记录展开
// （编译器报 `cannot use struct update syntax ... because it has private fields`），
// 所以「只给一半凭据」这类配置只有白盒测试造得出来。

///|
/// 策略 1（axios `valueFromConfig2`）：只取请求级。
/// 与策略 2 的关键差别是「请求级没有时也不回退」。
test "value_from_request never falls back to base" {
  assert_eq(value_from_request(Some("base"), Some("request")), Some("request"))
  assert_eq(value_from_request(Some("base"), None), None)
  assert_eq(value_from_request(None, Some("request")), Some("request"))
  assert_eq(value_from_request((None : String?), None), None)
}

///|
/// 策略 2（axios `defaultToConfig2`）：请求级优先，否则回退默认值。
test "prefer_request falls back to base" {
  assert_eq(prefer_request(Some("base"), Some("request")), Some("request"))
  assert_eq(prefer_request(Some("base"), None), Some("base"))
  assert_eq(prefer_request(None, Some("request")), Some("request"))
  assert_eq(prefer_request((None : String?), None), None)
}

///|
/// 策略 4（axios `mergeDirectKeys`）：本项目里与策略 2 同形。
///
/// 钉住这个事实，避免以后有人「顺手」把它改成别的语义：
/// 「关掉 validateStatus」在本项目里的写法是传恒真函数，不是删字段。
test "request_overrides behaves like prefer_request" {
  assert_eq(request_overrides(Some(1), Some(2)), Some(2))
  assert_eq(request_overrides(Some(1), None), Some(1))
  assert_eq(request_overrides((None : Int?), None), None)
}

///|
/// `auth` 逐字段深合并：默认值给用户名、请求只给密码，能拼出完整凭据。
///
/// 「只给一半凭据」的配置只有包内写得出来（见文件头），所以这条落在白盒测试里。
test "auth merges field by field" {
  let base = Config::default().with_auth("alice", "old-secret")
  let request : Config = {
    ..Config::default(),
    // 只提供 password，username 通过 Auth 的字段级深合并从默认值继承
    auth: Some({ ..Auth::default(), password: Some("new-secret"), }),
  }
  let merged = merge_config(base, request)
  let auth = merged.auth.unwrap()
  assert_eq(auth.username, Some("alice"))
  assert_eq(auth.password, Some("new-secret"))
}

///|
/// `proxy` 与 `auth` 同一档：逐字段深合并。
///
/// 「默认值给代理地址、请求级只给凭据」是这种用法的现实场景
/// （凭据由上层按请求注入），合并后地址与凭据必须同时在场——
/// 整个 `Proxy` 被替换掉的话，地址就丢了。
test "proxy merges field by field" {
  let base = Config::default().with_proxy("127.0.0.1", port=9000)
  let request : Config = {
    ..Config::default(),
    proxy: Some({
      ..Proxy::default(),
      auth: Some(Auth::{ username: Some("u"), password: Some("p"), }),
    }),
  }
  let merged = merge_config(base, request).proxy.unwrap()
  // 请求级没提地址：默认值的 host / port 保留下来
  assert_eq(merged.host, Some("127.0.0.1"))
  assert_eq(merged.port, Some(9000))
  assert_eq(merged.protocol, None)
  assert_eq(merged.auth.unwrap().username, Some("u"))
}

///|
/// `merge_proxy` 的四种组合（对应策略 3 的通用形状）：两侧都空则为空，
/// 只有一侧时原样保留，都有时逐字段以请求级为准。
test "merge_proxy keeps whichever side is present" {
  assert_true(merge_proxy(None, None) is None)
  let base : Proxy = { ..Proxy::default(), host: Some("127.0.0.1"), }
  let request : Proxy = { ..Proxy::default(), host: Some("proxy.corp"), }
  assert_eq(merge_proxy(Some(base), None).unwrap().host, Some("127.0.0.1"))
  assert_eq(merge_proxy(None, Some(base)).unwrap().host, Some("127.0.0.1"))
  assert_eq(
    merge_proxy(Some(base), Some(request)).unwrap().host,
    Some("proxy.corp"),
  )
}
