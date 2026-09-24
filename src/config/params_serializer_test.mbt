// `params_serializer` 这个扩展点的落位、合并与渲染。
// 它真的改变了发出去的 URL（端到端）在根包的 params_serializer_test.mbt。
//
// 单独一个文件而不是并进 merge_test.mbt：那个文件已经到上限，
// 而这一组用例围绕同一个字段，放一起更好找。

///|
/// 构建器把序列化器落到字段上，并且和别的构建器一样是值语义——设置它不会
/// 影响来源配置（「模板配置 + 逐个变体」的用法依赖这条）。
test "params serializer builder sets the field without mutating the source" {
  let template = @config.Config::default().with_params({ "tags": ["a", "b"] })
  let config = template.with_params_serializer(fn(_params) { "tags=a&tags=b" })
  assert_true(config.params_serializer is Some(_))
  assert_true(template.params_serializer is None)
  // 传进去的函数确实被原样保存：拿到的就是 params 本身，返回值就是 query 文本
  let serializer = config.params_serializer.unwrap()
  assert_eq(serializer({ "tags": ["a", "b"] }), "tags=a&tags=b")
}

///|
/// 默认没有这个字段：`Config::default()` 与内置默认值 `defaults()` 里都是 `None`
/// （内置规则不在字段里表达，而是 `serialize_params` 的固定行为）。
test "params serializer is absent by default" {
  assert_true(@config.Config::default().params_serializer is None)
  assert_true(@config.defaults().params_serializer is None)
}

///|
/// 合并走策略 2（axios 的 `defaultToConfig2`）：请求级提供就**整体替换**，
/// 否则回退实例默认值。
///
/// 「替换」这条要钉住：函数没法深合并，如果误用 `merge_json_option` 那类策略或
/// 者把两个函数串起来，表现就是「实例级规则在请求级之后又跑了一遍」。
test "params serializer merges by request overriding the instance default" {
  let instance = @config.Config::default().with_params_serializer(fn(_params) {
    "from=instance"
  })
  // 请求级没提供：沿用实例默认值
  let inherited = @config.merge_config(instance, @config.Config::new("/x"))
  let serializer = inherited.params_serializer.unwrap()
  assert_eq(serializer({}), "from=instance")
  // 请求级提供了：整体接管，实例默认值不再参与
  let overridden = @config.merge_config(
    instance,
    @config.Config::new("/x").with_params_serializer(fn(_params) {
      "from=request"
    }),
  )
  let serializer = overridden.params_serializer.unwrap()
  assert_eq(serializer({}), "from=request")
}

///|
/// 渲染成 `<fn>`（函数没有可打印的内容），位置紧跟 `params`，便于和 axios
/// 的配置项逐条对照。
test "params serializer renders as fn after params" {
  let config = @config.Config::default()
    .with_params({ "a": 1 })
    .with_params_serializer(fn(_params) { "a=1" })
  assert_true(
    config.to_string().contains("params: {\"a\":1}, params_serializer: <fn>"),
  )
}
