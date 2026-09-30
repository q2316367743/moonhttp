// jar 的两个动作：喂 Set-Cookie（`store`）、按请求 URL 取 `Cookie` 头值
// （`cookie_header`），以及两者共用的小规则（域匹配、路径匹配、默认路径）。
// 解析在 parse.mbt，数据形态在 types.mbt。

///|
/// 把一条 Set-Cookie 头喂进 jar：解析 → 按请求 URL 算归属 → 存库或删除。
///
/// 解析失败、URL 连 host 都没有、`Domain` 属性不是请求 host 的后缀，
/// 这几种情况**静默忽略**（RFC 6265 §5.3 的口径：坏 cookie 不报错，直接扔）。
/// `Max-Age <= 0` 或 `Expires` 已过时刻的同名 cookie 会被移除——这是
/// 服务端「让我删 cookie」的正规通道；没有同名旧 cookie 时同样无事发生。
pub fn CookieJar::store(
  self : CookieJar,
  url : String,
  set_cookie : String,
) -> Unit {
  let parsed = match parse_set_cookie(set_cookie) {
    Some(parsed) => parsed
    None => return
  }
  let host = match @url.url_host(url) {
    Some(host) => host
    None => return
  }
  // 归属域：带 Domain 属性时它必须是请求 host 或其后缀，否则整条忽略
  // （RFC 6265 §5.3 step 6）；不带就是 host-only，只有原主机收得到。
  let (domain, host_only) = match parsed.domain {
    Some(attr) =>
      if attr == host || host.has_suffix("." + attr) {
        (attr, false)
      } else {
        return
      }
    None => (host, true)
  }
  let request_path = @url.url_path(url).unwrap_or("/")
  let path = match parsed.path {
    Some(path) => path
    None => default_path(request_path)
  }
  // 过期时刻：Max-Age 优先于 Expires（RFC 6265 §5.3 step 3 的顺序）
  let now = now_ms()
  let expired : Bool = match parsed.max_age {
    Some(max_age) => max_age <= 0L
    None =>
      match parsed.expires_at {
        Some(at) => at <= now
        None => false
      }
  }
  let key : CookieKey = { domain, path, name: parsed.name, }
  if expired {
    // 「已过期」的写入按删除处理（RFC 6265 §4.1.1：过期时刻在过去的
    // Set-Cookie 就是被要求删掉旧 cookie）
    self.cookies.remove(key)
    return
  }
  let expires_at : UInt64? = match parsed.max_age {
    Some(max_age) => Some(add_max_age(now, max_age))
    None => parsed.expires_at
  }
  self.serial = self.serial + 1
  // 同名覆盖：值与属性换新，序号沿用旧的（RFC 把它当创建时间，
  // 覆盖不算重建，发送顺序不应因此变化）
  let serial = match self.cookies.get(key) {
    Some(old) => old.serial
    None => self.serial
  }
  self.cookies[key] = {
    name: parsed.name,
    value: parsed.value,
    domain,
    path,
    host_only,
    secure: parsed.secure,
    expires_at,
    serial,
  }
}

///|
/// 按请求 URL 算出该带的 `Cookie` 头值：过期清理 → 域 / 路径 / 安全匹配 →
/// 排序（归属路径长的在前，同长度按入库先后，RFC 6265 §5.4）→
/// 拼成 `n1=v1; n2=v2`。
///
/// 一个都不匹配时返回 `None`——调用方据此跳过注入，不会往请求上挂空的
/// `Cookie` 头。用户在请求里显式设置的 `Cookie` 头永远优先（注入走
/// `set_if_absent`，见 `Client::send_following_redirects`）。
pub fn CookieJar::cookie_header(self : CookieJar, url : String) -> String? {
  let host = match @url.url_host(url) {
    Some(host) => host
    None => return None
  }
  let path = @url.url_path(url).unwrap_or("/")
  let is_https = @url.url_scheme(url) == Some("https")
  let now = now_ms()
  let matched : Array[Cookie] = []
  // 过期不能边遍历边删（迭代中改 Map 的行为不可靠），先记下来最后一起删
  let expired_keys : Array[CookieKey] = []
  for key, cookie in self.cookies {
    match cookie.expires_at {
      Some(at) if at <= now => {
        expired_keys.push(key)
        continue
      }
      _ => ()
    }
    if domain_match(cookie, host) &&
      path_match(cookie.path, path) &&
      (!cookie.secure || is_https) {
      matched.push(cookie)
    }
  }
  for key in expired_keys {
    self.cookies.remove(key)
  }
  if matched.is_empty() {
    return None
  }
  sort_for_send(matched)
  let buf = StringBuilder()
  for index, cookie in matched {
    if index > 0 {
      buf.write_string("; ")
    }
    buf.write_string(cookie.name)
    buf.write_string("=")
    buf.write_string(cookie.value)
  }
  Some(buf.to_string())
}

///|
/// 当前时刻（Unix 毫秒）。过期判断的唯一时钟。
fn now_ms() -> UInt64 {
  @env.now()
}

///|
/// 域匹配（RFC 6265 §5.1.3 的精简版）：host-only 要求精确相等；
/// 带 Domain 属性的，请求 host 等于它或以 `.它` 结尾即匹配。
fn domain_match(cookie : Cookie, host : String) -> Bool {
  if cookie.host_only {
    return cookie.domain == host
  }
  cookie.domain == host || host.has_suffix("." + cookie.domain)
}

///|
/// 路径匹配（RFC 6265 §5.1.4）：相等，或 cookie-path 是请求路径的前缀
/// 且边界正好落在段上（请求路径以它续接 `/`，或 cookie-path 本身以 `/` 收尾）。
fn path_match(cookie_path : String, request_path : String) -> Bool {
  if request_path == cookie_path {
    return true
  }
  if request_path.has_prefix(cookie_path) {
    if cookie_path.has_suffix("/") {
      return true
    }
    if request_path[cookie_path.length():].has_prefix("/") {
      return true
    }
  }
  false
}

///|
/// 没带 Path 属性时的默认归属路径（RFC 6265 §5.1.4 的 default-path）：
/// 请求路径去掉最后一个 `/` 及其之后的部分；只有开头的斜杠时是 `/`。
fn default_path(request_path : String) -> String {
  if !request_path.has_prefix("/") {
    return "/"
  }
  match request_path.rev_find("/") {
    // 只有开头的那个斜杠（如 `/account`）：归属就是根路径
    Some(0) => "/"
    Some(index) => request_path[:index].to_owned()
    None => "/"
  }
}

///|
/// 发送顺序（RFC 6265 §5.4）：归属路径长的在前；同长度按入库先后。
/// 匹配集通常只有几枚，插入排序足够，也免得引入比较器 API 的负担。
fn sort_for_send(cookies : Array[Cookie]) -> Unit {
  for index in 1..<cookies.length() {
    let cookie = cookies[index]
    let mut slot = index
    while slot > 0 && after_in_send(cookies[slot - 1], cookie) {
      cookies[slot] = cookies[slot - 1]
      slot = slot - 1
    }
    cookies[slot] = cookie
  }
}

///|
/// `a` 是否该排在 `b` 后面（路径更短，或同路径但入库更晚）。
fn after_in_send(a : Cookie, b : Cookie) -> Bool {
  a.path.length() < b.path.length() ||
  (a.path.length() == b.path.length() && a.serial > b.serial)
}
