// cookie 包的黑盒测试：只从包外视角驱动 `CookieJar` 的公开 API，
// 解析层的已知值断言（日期、Max-Age）在 cookie_wbtest.mbt。
// 过期相关的用例用「过去 / 未来」两个固定日期表达，不依赖测试运行时刻。

///|
test "store a cookie and send it back on the same site" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/login", "session=abc; Path=/; Max-Age=3600")
  assert_eq(jar.cookie_header("https://example.com/x"), Some("session=abc"))
  assert_eq(jar.cookie_header("https://example.com/"), Some("session=abc"))
}

///|
/// 没有任何匹配时返回 `None`，调用方据此跳过注入（不挂空的 `Cookie` 头）。
test "no match yields None" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "a=1")
  assert_eq(jar.cookie_header("https://other.com/"), None)
  assert_eq(jar.cookie_header("not a url"), None)
}

///|
/// 解析失败（没有 `=`、名字为空）的 Set-Cookie 整条静默忽略。
test "malformed set-cookie is ignored" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "novalue")
  jar.store("https://example.com/", "=hidden; Path=/")
  assert_eq(jar.cookie_header("https://example.com/"), None)
}

///|
/// 属性名大小写不敏感；HttpOnly 与未知属性不影响存取；空值 cookie 合法。
test "attributes are case insensitive and unknown ones ignored" {
  let jar = @cookie.CookieJar::new()
  jar.store(
    "https://example.com/", "SESSION=abc; PATH=/; MAX-AGE=3600; HttpOnly; SameSite=Lax",
  )
  jar.store("https://example.com/", "empty=")
  assert_eq(
    jar.cookie_header("https://example.com/"),
    Some("SESSION=abc; empty="),
  )
}

///|
/// 没带 Domain 属性是 host-only：只发给当初设置它的那台主机，
/// 子域与父域都收不到（RFC 6265 §5.3 step 6）。
test "cookie without domain attribute is host only" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://api.example.com/", "a=1")
  assert_eq(jar.cookie_header("https://api.example.com/x"), Some("a=1"))
  assert_eq(jar.cookie_header("https://example.com/"), None)
  assert_eq(jar.cookie_header("https://other.api.example.com/"), None)
}

///|
/// 带 Domain 属性的 cookie 对子域可见：前导点剥掉、大小写归一；
/// Domain 不是请求 host 的后缀时整条忽略。
test "domain attribute grants subdomain access" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "a=1; Domain=example.com")
  jar.store("https://example.com/", "b=2; Domain=.EXAMPLE.com")
  jar.store("https://example.com/", "c=3; Domain=other.com")
  assert_eq(jar.cookie_header("https://sub.example.com/"), Some("a=1; b=2"))
  assert_eq(jar.cookie_header("https://example.com/"), Some("a=1; b=2"))
}

///|
/// 没带 Path 属性时按请求路径推导默认归属路径：去掉最后一个 `/` 及其后
/// 部分（RFC 6265 §5.1.4）。设在 `/a/b` 的 cookie 不发给根路径。
test "default path is derived from the request path" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/a/b/page", "deep=1")
  assert_eq(jar.cookie_header("https://example.com/a/b/other"), Some("deep=1"))
  assert_eq(jar.cookie_header("https://example.com/a/x"), None)
  assert_eq(jar.cookie_header("https://example.com/"), None)
}

///|
/// 显式 Path 的匹配以段为边界：`/foo` 匹配 `/foo/bar`，不匹配 `/foobar`。
test "explicit path matches on segment boundary" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "a=1; Path=/foo")
  assert_eq(jar.cookie_header("https://example.com/foo"), Some("a=1"))
  assert_eq(jar.cookie_header("https://example.com/foo/bar"), Some("a=1"))
  assert_eq(jar.cookie_header("https://example.com/foobar"), None)
  assert_eq(jar.cookie_header("https://example.com/bar/foo"), None)
}

///|
/// Secure 属性的 cookie 只随 https 发送。
test "secure cookie only travels over https" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "s=1; Secure")
  assert_eq(jar.cookie_header("https://example.com/"), Some("s=1"))
  assert_eq(jar.cookie_header("http://example.com/"), None)
}

///|
/// `Max-Age=0` 与过去的 `Expires` 都是删除信号：移除同名的旧 cookie。
test "expired write removes the stored cookie" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "a=1; Max-Age=3600")
  jar.store("https://example.com/", "a=1; Max-Age=0")
  assert_eq(jar.cookie_header("https://example.com/"), None)
  jar.store("https://example.com/", "b=1; Max-Age=3600")
  jar.store(
    "https://example.com/", "b=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT",
  )
  assert_eq(jar.cookie_header("https://example.com/"), None)
}

///|
/// 认不出的 `Expires` 让 cookie 退化为会话 cookie（继续存活），
/// 而不是把它删掉。
test "unparseable expires degrades to session cookie" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "a=1; Expires=nonsense")
  assert_eq(jar.cookie_header("https://example.com/"), Some("a=1"))
}

///|
/// `Max-Age` 优先于 `Expires`（RFC 6265 §5.3 step 3）：两个方向都成立。
test "max-age takes precedence over expires" {
  let jar = @cookie.CookieJar::new()
  // Max-Age 未过期、Expires 已过：活
  jar.store(
    "https://example.com/", "a=1; Max-Age=3600; Expires=Sun, 06 Nov 1994 08:49:37 GMT",
  )
  // Max-Age=0、Expires 未过：死
  jar.store(
    "https://example.com/", "b=1; Max-Age=0; Expires=Wed, 19 Feb 2069 00:00:00 GMT",
  )
  assert_eq(jar.cookie_header("https://example.com/"), Some("a=1"))
}

///|
/// 过期的 cookie 在读取时被顺手清掉（惰性清理），之后不再发送。
test "expired cookies are evicted lazily on read" {
  let jar = @cookie.CookieJar::new()
  jar.store(
    "https://example.com/", "old=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT",
  )
  jar.store("https://example.com/", "live=2")
  // 过期那枚不参与发送；jar 里也已经被清理
  assert_eq(jar.cookie_header("https://example.com/"), Some("live=2"))
  assert_eq(jar.cookie_header("https://example.com/"), Some("live=2"))
}

///|
/// 发送顺序（RFC 6265 §5.4）：归属路径长的在前；同长度按入库先后。
test "cookies are sorted by path length then creation order" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/a/b/c", "one=1")
  jar.store("https://example.com/a/b/c", "two=2; Path=/a/b/c")
  jar.store("https://example.com/a/b/c", "three=3")
  assert_eq(
    jar.cookie_header("https://example.com/a/b/c"),
    Some("two=2; one=1; three=3"),
  )
}

///|
/// 同名覆盖换值不换序：发送顺序维持原创建序（序号当创建时间用）。
test "overwriting keeps the original send order" {
  let jar = @cookie.CookieJar::new()
  jar.store("https://example.com/", "one=1")
  jar.store("https://example.com/", "two=2")
  jar.store("https://example.com/", "one=1b")
  assert_eq(jar.cookie_header("https://example.com/"), Some("one=1b; two=2"))
}
