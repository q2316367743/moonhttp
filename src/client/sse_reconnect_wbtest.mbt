// 自动重连的错误分类：哪些失败值得重试，哪些必须立刻抛。
// 白盒：`retryable_error` / `make_error` / `build_response` 都是包私有的。

///|
test "retryable_error retries network, timeout and 5xx only" {
  let config = Config::default()

  // 没有响应：网络失败与建连超时都是暂时性的
  assert_true(
    retryable_error(make_error("x", ErrorCode::Network, config, None)),
  )
  assert_true(
    retryable_error(make_error("x", ErrorCode::Timeout, config, None)),
  )

  // 取消永远不重试
  assert_false(
    retryable_error(make_error("x", ErrorCode::Cancelled, config, None)),
  )

  // 5xx 可重试
  let unavailable = make_error(
    "x",
    ErrorCode::BadResponse,
    config,
    Some(
      build_response(503, "Service Unavailable", Headers::new(), b"", config),
    ),
  )
  assert_true(retryable_error(unavailable))

  // 4xx 是请求本身的问题，重试没有意义
  let missing = make_error(
    "x",
    ErrorCode::BadRequest,
    config,
    Some(build_response(404, "Not Found", Headers::new(), b"", config)),
  )
  assert_false(retryable_error(missing))

  // 200 上的 BadResponse 是响应体解压失败，不是暂时性故障
  let broken = make_error(
    "x",
    ErrorCode::BadResponse,
    config,
    Some(build_response(200, "OK", Headers::new(), b"", config)),
  )
  assert_false(retryable_error(broken))
}
