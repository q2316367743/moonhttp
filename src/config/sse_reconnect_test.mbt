// SSE 自动重连策略的同步用例：默认值、构建器夹取、配置落位与合并。
// 策略本身是纯值类型，不需要起连接。

///|
test "sse reconnect defaults to unlimited with a 3000ms delay" {
  let policy = @config.SseReconnect::new()
  assert_eq(policy.max_retries, None)
  assert_eq(policy.default_delay, 3000)
}

///|
test "sse reconnect builders clamp negatives and keep the rest" {
  let clamped = @config.SseReconnect::new()
    .with_max_retries(-1)
    .with_default_delay(-5)
  assert_eq(clamped.max_retries, Some(0))
  assert_eq(clamped.default_delay, 0)

  let bounded = @config.SseReconnect::new().with_max_retries(3)
  assert_eq(bounded.max_retries, Some(3))
  assert_eq(bounded.default_delay, 3000)
}

///|
test "config with_sse_reconnect stores the whole policy" {
  let policy = @config.SseReconnect::new().with_max_retries(2)
  let config = @config.Config::default().with_sse_reconnect(policy)
  assert_eq(config.sse_reconnect, Some(policy))
}

///|
test "sse reconnect merges request over defaults as a whole" {
  let base = @config.Config::default().with_sse_reconnect(
    @config.SseReconnect::new().with_max_retries(1),
  )
  let request = @config.Config::default().with_sse_reconnect(
    @config.SseReconnect::new().with_max_retries(9).with_default_delay(10),
  )
  let merged = @config.merge_config(base, request)
  assert_eq(merged.sse_reconnect.unwrap().max_retries, Some(9))
  assert_eq(merged.sse_reconnect.unwrap().default_delay, 10)

  // 请求级没提供时回退实例默认值
  let inherited = @config.merge_config(base, @config.Config::default())
  assert_eq(inherited.sse_reconnect.unwrap().max_retries, Some(1))
}

///|
test "sse reconnect renders compactly in config to_string" {
  assert_eq(
    @config.SseReconnect::new().to_string(),
    "SseReconnect { max_retries: unlimited, default_delay: 3000 }",
  )
  let config = @config.Config::default().with_sse_reconnect(
    @config.SseReconnect::new().with_max_retries(3).with_default_delay(1000),
  )
  assert_eq(
    config.to_string(),
    "Config { sse_reconnect: SseReconnect { max_retries: 3, default_delay: 1000 } }",
  )
}
