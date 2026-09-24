// config 包的白盒测试：覆盖只有包内能触达的写法。

///|
/// 记录展开（`{ ..Config::default(), field: ... }`）与构建器等价，
/// 且**包内**可以给请求体字段直接赋值。
///
/// 这条只能写在白盒测试里：`Config.data` 是私有字段，包外的记录字面量 /
/// 记录展开会被编译器拒绝（`cannot use struct update syntax ... because it has
/// private fields`），所以外部使用者构造配置只有构建器一条路；
/// 包内则两者都成立——构建器自己就是这么实现的。
test "record spread is equivalent to builders" {
  let config : Config = {
    ..Config::default(),
    url: Some("/users"),
    http_method: Some(Method::Get),
  }
  assert_eq(config.url, Some("/users"))
  assert_eq(config.http_method, Some(Method::Get))
  assert_eq(config.base_url, None)
  // 请求体这样写进来，与 with_data_from_json 的结果一致
  let spread : Config = {
    ..Config::default(),
    data: Some(Body::Json({ "a": 1 })),
  }
  assert_eq(
    spread.serialize_body().bytes,
    Config::default().with_data_from_json({ "a": 1 }).serialize_body().bytes,
  )
}
