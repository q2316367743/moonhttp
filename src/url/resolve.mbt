// URL 的切分、相对解析（RFC 3986 §5.2–§5.3）与 scheme / authority 提取。
//
// 与 combine.mbt 的分工：那边是 axios 的 `combineURLs`——纯字符串拼接
// （去尾斜杠、中间补一个斜杠）；这里是标准的相对解析，供重定向使用：
// `Location` 可能是 `/x`、`../x`、`?q=1`、`//host/x` 或完整地址，
// 只有按 RFC 解析才能都落到正确的绝对地址上，点段也要按规范归并。

///|
/// 切分出来的 URL 零件。端口不在这里归一化（那是 `url_authority` 的职责），
/// 这一步只做「切成 scheme / authority / path / query」。
priv struct ParsedUrl {
  /// 小写 scheme，不含 `://`
  scheme : String
  /// authority 原文，可能含 userinfo 与端口
  authority : String
  /// 以 `/` 开头的路径；地址里没有路径时是空串
  path : String
  /// 不含前导 `?` 的 query；没有 query 时是 `None`
  query : String?
}

///|
/// 取 URL 的 scheme（小写，不含 `://`）。
///
/// 只认 `scheme://` 形式，与 `is_absolute_url` 的口径一致：`mailto:x@y`
/// 这类「有 scheme 但没有 authority」的地址在这里返回 `None`。
pub fn url_scheme(url : String) -> String? {
  match parse_absolute(url) {
    Some(parsed) => Some(parsed.scheme)
    None => None
  }
}

///|
/// 取 URL 的 authority 归一化形式：去掉 userinfo、主机名转小写、默认端口去掉
/// （`http` 的 `:80`、`https` 的 `:443`）。
///
/// 归一化是为了比较：Node 的 `URL` 会把默认端口抹掉，`https://a.com` 与
/// `https://a.com:443` 是同一个 host。不归一化的话，一次「重定向到显式写了
/// 默认端口的同 host 地址」会被误判成换了 host，白丢一次凭据。
///
/// 地址不是 `scheme://` 形式时返回 `None`。
pub fn url_authority(url : String) -> String? {
  let parsed = match parse_absolute(url) {
    Some(parsed) => parsed
    None => return None
  }
  // userinfo 里不会出现未编码的 `@`（RFC 3986 §3.2），第一个 `@` 就是分隔符。
  let host_port = match parsed.authority.find("@") {
    Some(index) => parsed.authority[index + 1:]
    None => parsed.authority
  }
  let (host, port) = split_host_port(host_port)
  let default_port = match parsed.scheme {
    "http" => Some("80")
    "https" => Some("443")
    _ => None
  }
  let port = match port {
    Some(port) => if default_port == Some(port) { None } else { Some(port) }
    None => None
  }
  match port {
    Some(port) => Some(host + ":" + port)
    None => Some(host)
  }
}

///|
/// 把一个相对引用解析成绝对地址（RFC 3986 §5.2.2 的解析算法）。
///
/// 结果**一定不含 fragment**：fragment 从不随请求发出（`build_url` 也只会在
/// 追加 query 时顺手丢掉它），留着重定向的下一跳就可能把 `#frag` 当路径发出去。
///
/// 只有基地址必须是绝对地址这一条会失败（返回 `None`）：引用本身无论多奇怪
/// 都能解析出一个地址——「ftp://x」这类不支持的 scheme 也照样解析出来，
/// 能不能发出去由传输层的 `split_url` 判定，这一层只回答「地址长什么样」。
///
/// 与 axios / follow-redirects 的一条边界差异：把「scheme 后跟 `//`」当作
/// 绝对地址的判据（复用 `is_absolute_url`，也就是 axios 的 `isAbsoluteURL`），
/// 所以 `Location: mailto:x` 会被当成相对路径而不是带 scheme 的引用。
/// 正常服务端不会这么写 Location。
pub fn resolve_url(base : String, location : String) -> String? {
  let base = match parse_absolute(base) {
    Some(parsed) => parsed
    None => return None
  }
  let location = location.trim()
  // 空引用：落到基地址自身（RFC 3986 §5.2.2 里 `R.path == ""` 且无 query 的分支）。
  if location.is_empty() {
    return Some(compose(base, base.path, base.query))
  }
  // 只有 fragment 变化：目标还是同一个资源，等同于重新请求基地址。
  // （会不会变成死循环由 `max_redirects` 兜底，不在这一层判断。）
  if location.has_prefix("#") {
    return Some(compose(base, base.path, base.query))
  }
  if is_absolute_url(location) {
    // 协议相对地址（`//host/x`）借基地址的 scheme，其余原样采用。
    let absolute = strip_fragment(location)
    if absolute.has_prefix("//") {
      return Some(base.scheme + ":" + absolute)
    }
    return Some(absolute)
  }
  // 相对引用：先切掉 fragment，再切成 path 与 query（RFC 3986 §5.2.2 的 R.path / R.query）。
  // query 必须在归并点段之前切出来，否则 `a/..?x=1` 里的 `..?x=1` 会被当成普通段。
  let reference = strip_fragment(location)
  let (ref_path, ref_query) = match reference.find("?") {
    Some(index) => (reference[:index], Some(reference[index + 1:].to_owned()))
    None => (reference, None)
  }
  if ref_path.has_prefix("/") {
    // 根相对：authority 不变，路径整体换成引用里的路径。
    return Some(compose(base, remove_dot_segments(ref_path), ref_query))
  }
  if ref_path.is_empty() {
    // 只给了 query（`?x=1`）：路径沿用基地址。
    return Some(compose(base, base.path, ref_query))
  }
  // 相对路径：与基地址所在目录合并后再归并点段。
  let merged = remove_dot_segments(merge_paths(base, ref_path))
  Some(compose(base, merged, ref_query))
}

///|
/// 切分一个**绝对地址**；不是 `scheme://` 形式、或 scheme 文法非法时返回 `None`。
fn parse_absolute(url : String) -> ParsedUrl? {
  let scheme_end = match url.find("://") {
    Some(index) => index
    None => return None
  }
  let scheme = url[:scheme_end]
  if !is_valid_scheme(scheme) {
    return None
  }
  let rest = url[scheme_end + 3:]
  // authority 到第一个 `/`、`?`、`#` 为止。
  let authority_end = match rest.find_by(is_authority_end) {
    Some(index) => index
    None => rest.length()
  }
  let authority = rest[:authority_end]
  // 先切 fragment 再切 query：`#` 之后的一切都不属于请求目标。
  let tail = strip_fragment(rest[authority_end:])
  let (path, query) = match tail.find("?") {
    Some(index) => (tail[:index].to_owned(), Some(tail[index + 1:].to_owned()))
    None => (tail, None)
  }
  Some({
    scheme: scheme.to_lower().to_owned(),
    authority: authority.to_owned(),
    path,
    query,
  })
}

///|
fn is_authority_end(c : Char) -> Bool {
  c == '/' || c == '?' || c == '#'
}

///|
/// 去掉 `#` 及其之后的部分，返回新字符串（没有 `#` 时原样返回）。
fn strip_fragment(url : StringView) -> String {
  match url.find("#") {
    Some(index) => url[:index].to_owned()
    None => url.to_owned()
  }
}

///|
/// 把 URL 的 authority 拆成「主机名」（保留 IPv6 的方括号）与可选端口。
///
/// IPv6 字面量里的冒号不能当端口分隔符，所以带 `[` 的走 `]` 之后找端口，
/// 其余取最后一个 `:`——`example.com:8080` 这样切才对。
fn split_host_port(host_port : StringView) -> (String, String?) {
  if host_port.has_prefix("[") {
    match host_port.find("]") {
      Some(close) => {
        let host = host_port[:close + 1].to_lower().to_owned()
        let tail = host_port[close + 1:]
        if tail.has_prefix(":") {
          (host, Some(tail[1:].to_owned()))
        } else {
          (host, None)
        }
      }
      None => (host_port.to_lower().to_owned(), None)
    }
  } else {
    match host_port.rev_find(":") {
      Some(colon) =>
        (
          host_port[:colon].to_lower().to_owned(),
          Some(host_port[colon + 1:].to_owned()),
        )
      None => (host_port.to_lower().to_owned(), None)
    }
  }
}

///|
/// 相对路径与基地址所在目录的合并（RFC 3986 §5.3 的 merge）：
/// 基地址路径从最后一个 `/` 起截断（含它），不足时用 `/` 补。
fn merge_paths(base : ParsedUrl, relative : StringView) -> String {
  if base.authority.length() > 0 && base.path.length() == 0 {
    return "/" + relative.to_owned()
  }
  let directory = match base.path.rev_find("/") {
    Some(index) => base.path[:index + 1]
    None => ""
  }
  directory.to_owned() + relative.to_owned()
}

///|
/// 归并路径里的 `.` 与 `..` 段（RFC 3986 §5.2.4）。
///
/// 用「切段 → 重建」实现：切出来的第一个空段代表根（绝对路径），
/// 它不参与 `..` 回退，所以 `/../a` 归并成 `/a` 而不是 `a`。
fn remove_dot_segments(path : StringView) -> String {
  let parts : Array[StringView] = []
  for segment in path.split("/") {
    parts.push(segment)
  }
  let start = if parts.length() > 0 && parts[0].is_empty() { 1 } else { 0 }
  let out : Array[String] = []
  for index in start..<parts.length() {
    let segment = parts[index]
    let last = index == parts.length() - 1
    if segment == "." {
      // 末尾的 `.` 要留下一个空段，否则 `/a/.` 会退化成 `/a` 而不是 `/a/`。
      if last {
        out.push("")
      }
    } else if segment == ".." {
      ignore(out.pop())
      if last {
        out.push("")
      }
    } else {
      out.push(segment.to_owned())
    }
  }
  let buf = StringBuilder()
  for index, segment in out {
    if index > 0 {
      buf.write_string("/")
    }
    buf.write_string(segment)
  }
  let body = buf.to_string()
  if start == 1 {
    "/" + body
  } else {
    body
  }
}

///|
/// 拼回 `scheme://authority path [?query]`。`path` 以 `/` 开头（或为空）。
fn compose(base : ParsedUrl, path : String, query : String?) -> String {
  let buf = StringBuilder()
  buf.write_string(base.scheme)
  buf.write_string("://")
  buf.write_string(base.authority)
  buf.write_string(path)
  match query {
    Some(query) => {
      buf.write_string("?")
      buf.write_string(query)
    }
    None => ()
  }
  buf.to_string()
}
