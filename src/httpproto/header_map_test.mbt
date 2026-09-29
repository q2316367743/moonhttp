// HeaderMap（协议层 multimap）的规则测试：不丢信息是它的存在理由。

///|
/// 大小写不敏感命中、原始拼写保留——与门面层 `Headers` 同一口径。
test "lookup is case insensitive and original spelling is kept" {
  let map = @httpproto.HeaderMap::new()
  map.append("Content-Type", "application/json")
  assert_eq(map.get_first("content-type"), Some("application/json"))
  assert_eq(map.get_first("CONTENT-TYPE"), Some("application/json"))
  assert_true(map.has("Content-TYPE"))
  // 条目里记住的是写入时的拼写
  assert_eq(map.entries[0].0, "Content-Type")
}

///|
/// 同名重复不合并：first 是第一条、last 是最后一条、all 按线上顺序全给。
/// 这是协议层与门面层单值 Headers 的本质差别（Set-Cookie 不能合并）。
test "repeated names keep every value" {
  let map = @httpproto.HeaderMap::new()
  map.append("Set-Cookie", "a=1")
  map.append("X-Trace", "t")
  map.append("Set-Cookie", "b=2")
  assert_eq(map.get_first("Set-Cookie"), Some("a=1"))
  assert_eq(map.get_last("Set-Cookie"), Some("b=2"))
  assert_eq(map.get_all("Set-Cookie"), ["a=1", "b=2"])
  assert_eq(map.get_all("X-Trace"), ["t"])
  assert_eq(map.get_all("X-Missing"), ([] : Array[String]))
  assert_eq(map.length(), 3)
}

///|
/// `set` 覆盖同名全部条目；`set_if_absent` 不动已有值（自动补默认头的口径）；
/// `remove` 移除同名全部并保持其余条目的相对顺序。
test "set, set_if_absent and remove behave like the facade contract" {
  let map = @httpproto.HeaderMap::new()
  map.append("Accept", "text/html")
  map.append("Content-Encoding", "gzip")
  map.append("Accept", "application/json")
  map.set("Accept", "*/*")
  assert_eq(map.get_all("Accept"), ["*/*"])
  assert_eq(map.length(), 2)
  map.set_if_absent("Accept", "nope")
  map.set_if_absent("Host", "api.example.com")
  assert_eq(map.get_first("Accept"), Some("*/*"))
  assert_eq(map.get_first("Host"), Some("api.example.com"))
  map.remove("Content-Encoding")
  assert_false(map.has("Content-Encoding"))
  // 顺序：Accept 在前，Host 在后
  assert_eq(map.entries[0].0, "Accept")
  assert_eq(map.entries[1].0, "Host")
}
