// URL 的零件提取：主机名与路径，cookie 的归属与匹配用。
//
// 与 resolve.mbt 的分工：那边为「重定向解析」服务；这里为「请求 URL 属于谁」
// 服务——cookie 的域匹配只看主机名（RFC 6265 明确端口不参与匹配），路径匹配
// 只看 path。两者都是 `parse_absolute` 的薄封装，单独成文件只因 resolve.mbt
// 已贴近 300 行上限（RL-04）。

///|
/// 取 URL 的主机名（小写，不含端口与 userinfo；IPv6 字面量保留方括号）。
///
/// 供 cookie 的域匹配使用：RFC 6265 的 domain 只按名字匹配、与端口无关，
/// 所以这里有意抹掉端口（与 `url_authority` 为重定向比较而保留非默认端口
/// 的口径不同）。地址不是 `scheme://` 形式时返回 `None`。
pub fn url_host(url : String) -> String? {
  let parsed = match parse_absolute(url) {
    Some(parsed) => parsed
    None => return None
  }
  // userinfo 里不会出现未编码的 `@`（RFC 3986 §3.2），第一个 `@` 就是分隔符。
  let host_port = match parsed.authority.find("@") {
    Some(index) => parsed.authority[index + 1:]
    None => parsed.authority
  }
  let (host, _port) = split_host_port(host_port)
  Some(host)
}

///|
/// 取 URL 的路径，以 `/` 开头；地址里没有路径部分时返回 `"/"`。
///
/// 供 cookie 的路径匹配使用：请求 URL 的 path 决定默认 cookie-path 与
/// 「哪些 cookie 属于这个请求」（RFC 6265 §5.1.4 / §5.4）。
/// 地址不是 `scheme://` 形式时返回 `None`。
pub fn url_path(url : String) -> String? {
  match parse_absolute(url) {
    Some(parsed) =>
      if parsed.path.is_empty() {
        Some("/")
      } else {
        Some(parsed.path)
      }
    None => None
  }
}
