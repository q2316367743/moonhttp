// 重定向的下一跳规则：这次响应要不要跟随、跟随到哪里，以及方法 / body / 凭据 / 头
// 怎么改写。规则逐条对齐 follow-redirects 1.16（axios 在 Node 上用的就是它），
// 有意保留的差异见 docs/08-redirects.md。
//
// 与 `merge.mbt` 同包不是偶然：方法改写成 GET 时要清空请求体，而 `Config.data`
// 是私有字段——包外连记录展开都写不出来（理由见 merge.mbt 顶部的注释）。
//
// 这里**不计数**：跟几跳、什么时候算超限由根包的重定向循环决定，
// 本文件只回答「给定这次响应与当前地址，下一跳长什么样」。

///|
/// 这次响应要不要跟随？要跟就返回**下一跳的配置**，不要跟返回 `None`。
///
/// `current_url` 是产出这份响应的完整地址（`PreparedRequest.url`，已经含
/// `base_url` 拼接结果与序列化后的 query）：相对 `Location` 必须相对**实际发出去的
/// 地址**解析，而不是配置里那个没拼过的 `url`。
///
/// 返回 `None` 的三种情况：
/// - 状态码不在 3xx：正常响应，原样交出去；
/// - 没有 `Location` 头，或它的值是空白：follow-redirects 里 `!location` 直接走
///   「不是重定向」这条分支，于是 3xx 落到 `validate_status` 手里由调用方定夺；
/// - `Location` 解析不出绝对地址（基地址不是绝对地址）：当成不可跟随。
///
/// 下一跳的配置里，这几项被改写：
/// - `url` 换成解析出的绝对地址（不含 fragment），`base_url` 与 `params` 清空
///   ——query 已经在那个地址里，再参与一次就是二次拼接 / 二次追加；
/// - `http_method` 按状态码决定（见 `rewrites_to_get`），改写成 GET 时连
///   `data` 与 `content-*` 头一起丢掉；
/// - 凭据（`Authorization` / `Proxy-Authorization` / `Cookie` 与 `auth` 字段）
///   在跨 host 或协议降级时丢掉（见 `keeps_credentials`）；
/// - 用户显式设的 `Host` 头一律丢掉，让传输层按新地址重新生成。
///
/// 其余字段（`timeout` / `max_redirects` / `validate_status` / 各层头…）原样保留。
pub fn Config::next_redirect(
  self : Config,
  current_url : String,
  status : Int,
  location : String?,
) -> Config? {
  if status < 300 || status >= 400 {
    return None
  }
  let location = match location {
    Some(location) => location.trim().to_owned()
    None => return None
  }
  if location.is_empty() {
    return None
  }
  let next_url = match @url.resolve_url(current_url, location) {
    Some(next_url) => next_url
    None => return None
  }
  // 方法缺省时按 HTTP 的约定当 GET——与 `util.resolve_method` 的兜底一致。
  let meth = self.http_method.unwrap_or(Method::Get)
  let to_get = rewrites_to_get(status, meth)
  let keeps_credentials = keeps_credentials_across(current_url, next_url)
  let matches = fn(name : String) -> Bool {
    if name.to_lower() == "host" {
      return true
    }
    if to_get && name.to_lower().has_prefix("content-") {
      return true
    }
    if !keeps_credentials && is_sensitive_header(name) {
      return true
    }
    false
  }
  let next : Config = {
    ..self,
    url: Some(next_url),
    base_url: None,
    params: None,
    http_method: Some(if to_get { Method::Get } else { meth }),
    // body 与 `content-*` 是一体的：GET 不该带实体，留着 body 只会让
    // `serialize_body` 再把 `Content-Type` 补回来。
    data: if to_get {
      None
    } else {
      self.data
    },
    // 凭据丢了的话 `auth` 也必须清掉：`build_prepared_request` 会据它重新补
    // `Authorization`，只删头等于白删。
    auth: if keeps_credentials {
      self.auth
    } else {
      None
    },
  }
  Some(next.with_dropped_headers(matches))
}

///|
/// 这次重定向要不要把方法改写成 GET（follow-redirects 的两个条件）：
/// - 301/302 且当前方法正是 POST：历史原因（RFC 9110 §15.4.2 / §15.4.3），
///   浏览器与客户端普遍把 POST 降级成 GET；
/// - 303 且当前方法不是 GET/HEAD：`See Other` 的语义就是「去 GET 那个资源」。
///
/// 307/308 一律保持方法（那两个状态码的存在意义就是「原样重发」），
/// 301/302 上的非 POST（PUT / PATCH…）也保持——这正是 follow-redirects 的行为。
fn rewrites_to_get(status : Int, meth : Method) -> Bool {
  if status == 301 || status == 302 {
    meth == Method::Post
  } else if status == 303 {
    meth != Method::Get && meth != Method::Head
  } else {
    false
  }
}

///|
/// 下一跳还能不能带凭据（`Authorization` / `Proxy-Authorization` / `Cookie`）。
///
/// 规则来自 follow-redirects：**协议换了且新协议不是 https**（也就是降级到明文），
/// 或者 **host 换了且新 host 不是旧 host 的子域**，就丢。
/// 于是两种「看起来还行」的情况会保留凭据：同 host 的 http→https 升级、
/// 以及跳到自己的子域。host 比较用的是归一化后的 authority
/// （去 userinfo、host 小写、默认端口去掉，见 `@url.url_authority`），
/// 所以「同 host 但显式写了默认端口」不会被误判成换 host 白丢一次凭据。
fn keeps_credentials_across(from_url : String, to_url : String) -> Bool {
  let from_scheme = @url.url_scheme(from_url)
  let to_scheme = @url.url_scheme(to_url)
  if from_scheme != to_scheme && to_scheme != Some("https") {
    return false
  }
  let from_host = @url.url_authority(from_url)
  let to_host = @url.url_authority(to_url)
  if from_host == to_host {
    return true
  }
  match (from_host, to_host) {
    // 解析不出 authority 时保守处理：宁可丢凭据，不能把凭据发到不认识的地址。
    (Some(from_host), Some(to_host)) => is_subdomain_of(to_host, from_host)
    _ => false
  }
}

///|
/// `subdomain` 是不是 `domain` 的子域（follow-redirects 的 `isSubdomain`）：
/// 必须严格更长、以 `.` 分隔、且以 domain 结尾。`example.com.evil.com` 这种
/// 「后缀相同但换了一家」的地址不算，`a.example.com` 算。
fn is_subdomain_of(subdomain : String, domain : String) -> Bool {
  let dot = subdomain.length() - domain.length() - 1
  if dot <= 0 {
    return false
  }
  // 分隔点那个位置上必须是 `.`：切片把它包含进来判后缀，不按下标取字符。
  subdomain[:dot + 1].has_suffix(".") && subdomain.has_suffix(domain)
}

///|
/// follow-redirects 里跨边界要丢掉的敏感头（`sensitiveHeaders`）。
fn is_sensitive_header(name : String) -> Bool {
  match name.to_lower() {
    "authorization" | "proxy-authorization" | "cookie" => true
    _ => false
  }
}

///|
/// 删掉三层头里所有命中 `matches` 的头，返回新的 `Config`。
///
/// 三层都扫的原因：头是在 `build_prepared_request`（util 包）里才拍平的，
/// 到那时 `Authorization` / `Content-Type` 由哪一层贡献已经分不出来——
/// 只删请求级那层会漏掉写在 `common_headers` 或按方法层里的同名头。
fn Config::with_dropped_headers(
  self : Config,
  matches : (String) -> Bool,
) -> Config {
  {
    ..self,
    headers: drop_matching_option(self.headers, matches),
    common_headers: drop_matching_option(self.common_headers, matches),
    method_headers: drop_method_headers(self.method_headers, matches),
  }
}

///|
fn drop_matching_option(
  headers : Headers?,
  matches : (String) -> Bool,
) -> Headers? {
  match headers {
    Some(headers) => Some(drop_matching(headers, matches))
    None => None
  }
}

///|
/// 按方法分层的头整体过一遍同样的过滤：命中即从每个桶里删。
fn drop_method_headers(
  buckets : Map[Method, Headers]?,
  matches : (String) -> Bool,
) -> Map[Method, Headers]? {
  match buckets {
    Some(buckets) => {
      // 先 copy 再改：buckets 可能被别的 Config 引用着，就地改会破坏值语义。
      let filtered = buckets.copy()
      for meth, headers in buckets {
        filtered[meth] = drop_matching(headers, matches)
      }
      Some(filtered)
    }
    None => None
  }
}

///|
/// `Headers` 只提供「按名删」，所以这里先遍历出需要删的拼写再逐个删。
/// 判定用的名字由 `matches` 自己统一大小写，这里不假设头名已经是小写。
fn drop_matching(headers : Headers, matches : (String) -> Bool) -> Headers {
  let mut result = headers
  for entry in headers.entries() {
    if matches(entry.0) {
      result = result.remove(entry.0)
    }
  }
  result
}
