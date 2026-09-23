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
