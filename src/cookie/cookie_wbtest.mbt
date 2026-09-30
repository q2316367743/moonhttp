// cookie 包的白盒测试：直接断言私有解析函数的已知值。
// 行为级用例在 cookie_test.mbt，这里钉的是解析层的边界。

///|
/// IMF-fixdate 的三个已知时刻：RFC 7231 的示例、闰年 2 月 29 日、
/// 1970 年之前的日期钳成 0。
test "parse imf-fixdate" {
  assert_eq(
    parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"),
    Some(784111777000UL),
  )
  assert_eq(
    parse_http_date("Wed, 29 Feb 2000 00:00:00 GMT"),
    Some(951782400000UL),
  )
  assert_eq(parse_http_date("Mon, 01 Jan 1900 00:00:00 GMT"), Some(0UL))
}

///|
/// 解析的宽松面（星期可省、月名大小写、多余空白）与严格面（残缺即弃）。
test "imf-fixdate leniency and rejection" {
  assert_eq(parse_http_date("06 Nov 1994 08:49:37 GMT"), Some(784111777000UL))
  assert_eq(
    parse_http_date("Sun, 06 nov 1994 08:49:37 GMT"),
    Some(784111777000UL),
  )
  assert_eq(parse_http_date("Sun, 06 Nov 94 08:49:37 GMT"), None)
  assert_eq(parse_http_date("nonsense"), None)
  assert_eq(parse_http_date(""), None)
}

///|
/// Max-Age 只认「可选负号 + 纯数字」。
test "parse max-age" {
  assert_eq(parse_max_age("3600"), Some(3600L))
  assert_eq(parse_max_age("0"), Some(0L))
  assert_eq(parse_max_age("-1"), Some(-1L))
  assert_eq(parse_max_age(""), None)
  assert_eq(parse_max_age("abc"), None)
  assert_eq(parse_max_age("1x"), None)
  assert_eq(parse_max_age("+1"), None)
}

///|
/// 默认归属路径：去掉最后一个 `/` 及其之后的部分；只有开头斜杠时是根。
test "default path" {
  assert_eq(default_path("/a/b/c"), "/a/b")
  assert_eq(default_path("/account"), "/")
  assert_eq(default_path("/"), "/")
  assert_eq(default_path(""), "/")
  assert_eq(default_path("relative"), "/")
}

///|
/// 路径匹配以段为边界（RFC 6265 §5.1.4 的全部情形）。
test "path match boundary" {
  assert_true(path_match("/foo", "/foo"))
  assert_true(path_match("/foo", "/foo/bar"))
  assert_true(path_match("/foo/", "/foo/bar"))
  assert_true(path_match("/", "/anything"))
  assert_false(path_match("/foo", "/foobar"))
  assert_false(path_match("/foo", "/fo"))
  assert_false(path_match("/foo", "/bar/foo"))
}

///|
/// 域匹配：host-only 精确相等；带 Domain 的做「等或后缀」。
test "domain match" {
  let host_only : Cookie = {
    name: "a",
    value: "1",
    domain: "api.example.com",
    path: "/",
    host_only: true,
    secure: false,
    expires_at: None,
    serial: 0,
  }
  let domain_cookie = { ..host_only, host_only: false, domain: "example.com", }
  assert_true(domain_match(host_only, "api.example.com"))
  assert_false(domain_match(host_only, "example.com"))
  assert_false(domain_match(host_only, "other.api.example.com"))
  assert_true(domain_match(domain_cookie, "example.com"))
  assert_true(domain_match(domain_cookie, "sub.example.com"))
  assert_false(domain_match(domain_cookie, "notexample.com"))
}
