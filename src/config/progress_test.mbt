// 进度回调（`on_upload_progress` / `on_download_progress`）的类型与配置：
// `ProgressEvent::progress` 的计算、两个构建器、合并策略与渲染。
//
// 「回调真的在传输过程中被调用」的端到端用例在根包的 `progress_test.mbt`；
// 这里只管配置层，不碰网络。

///|
/// `progress()` 只在 total 已知且为正时给比例。
///
/// 三种「给不出比例」的情况都要钉住：total 未知（chunked 响应）、total 为 0、
/// 以及 loaded 超过 total（压缩响应里 total 是压缩后的长度）——最后一种不截断，
/// 截断会把「服务端给的 total 不对」这件事藏起来。
test "progress ratio is computed only from a known positive total" {
  assert_eq(
    ({ loaded: 50, total: Some(100), } : @config.ProgressEvent).progress(),
    Some(0.5),
  )
  assert_eq(
    ({ loaded: 10, total: None, } : @config.ProgressEvent).progress(),
    None,
  )
  assert_eq(
    ({ loaded: 10, total: Some(0), } : @config.ProgressEvent).progress(),
    None,
  )
  assert_eq(
    ({ loaded: 200, total: Some(100), } : @config.ProgressEvent).progress(),
    Some(2.0),
  )
}

///|
/// 两个构建器把回调落到字段上，并且和别的构建器一样是值语义——设置它不会
/// 影响来源配置（「模板配置 + 逐个变体」的用法依赖这条）。
test "progress builders set the fields without mutating the source" {
  let template = @config.Config::default().with_url("/upload")
  let seen : Array[Int] = []
  let config = template
    .with_on_upload_progress(fn(_event) { () })
    .with_on_download_progress(fn(event) { seen.push(event.loaded) })
  assert_true(config.on_upload_progress is Some(_))
  assert_true(config.on_download_progress is Some(_))
  assert_true(template.on_upload_progress is None)
  assert_true(template.on_download_progress is None)
  // 传进去的函数确实被原样保存：调用它就能观察到这次事件
  let report = config.on_download_progress.unwrap()
  report({ loaded: 7, total: Some(9), })
  assert_eq(seen, [7])
}

///|
/// 默认两个字段都是 `None`（不报告进度），内置默认值 `defaults()` 里同样如此。
test "progress callbacks are absent by default" {
  assert_true(@config.Config::default().on_upload_progress is None)
  assert_true(@config.Config::default().on_download_progress is None)
  assert_true(@config.defaults().on_upload_progress is None)
  assert_true(@config.defaults().on_download_progress is None)
}

///|
/// 合并走策略 2（axios 的 `defaultToConfig2`）：请求级提供就**整体替换**，
/// 否则回退实例默认值。
///
/// 「替换」这条要钉住：函数没法深合并，如果被串成一条链，表现就是
/// 「实例级的回调在请求级之后又收到一遍进度」——同一个进度报两次。
/// 两个方向的回调各自独立替换，不互相影响。
test "progress callbacks merge by request overriding the instance default" {
  let from_instance : Array[String] = []
  let from_request : Array[String] = []
  let instance = @config.Config::default()
    .with_on_upload_progress(fn(_event) { from_instance.push("instance") })
    .with_on_download_progress(fn(_event) { from_instance.push("instance") })
  // 请求级没提供：沿用实例默认值
  let inherited = @config.merge_config(instance, @config.Config::new("/x"))
  inherited.on_upload_progress.unwrap()({ loaded: 1, total: None, })
  inherited.on_download_progress.unwrap()({ loaded: 1, total: None, })
  assert_eq(from_instance, ["instance", "instance"])
  assert_eq(from_request, [])
  // 请求级提供了：整体接管，实例默认值不再参与
  let overridden = @config.merge_config(
    instance,
    @config.Config::new("/x")
    .with_on_upload_progress(fn(_event) { from_request.push("request") })
    .with_on_download_progress(fn(_event) { from_request.push("request") }),
  )
  overridden.on_upload_progress.unwrap()({ loaded: 1, total: None, })
  overridden.on_download_progress.unwrap()({ loaded: 1, total: None, })
  assert_eq(from_instance, ["instance", "instance"])
  assert_eq(from_request, ["request", "request"])
}

///|
/// 渲染成 `<fn>`（函数没有可打印的内容），位置紧跟 `params_serializer`，
/// 便于和 axios 的配置项逐条对照。
test "progress callbacks render as fn" {
  let config = @config.Config::default()
    .with_on_upload_progress(fn(_event) { () })
    .with_on_download_progress(fn(_event) { () })
  assert_true(
    config
    .to_string()
    .contains("on_upload_progress: <fn>, on_download_progress: <fn>"),
  )
}
