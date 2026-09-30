// 把 `PreparedRequest.url` 切成「拨号要的地址」与「请求行要的目标」。
//
// 切法（`://` 之后第一个 `/`）：自研栈要自己建连、
// 自己拼 Host，所以多拆出 host 与端口（含按 scheme 补默认值）。

///|
/// 一个可以拨号的请求目标。
pub(all) struct Target {
  /// 小写 scheme：`http` / `https` / `socks5`（socks5 只为代理地址解析而认识，
  /// 作为请求目标会被上层拒绝）
  scheme : String
  /// 是否在连接上叠 TLS
  use_tls : Bool
  /// 主机名（CONNECT 的隧道地址、TLS 的 SNI、`Host` 头的主机段都用它）
  host : String
  /// 端口；URL 里没写时按 scheme 补默认值（http 80 / https 443）
  port : Int
  /// 请求目标（origin-form，即 path?query）；URL 没有路径时为 `/`
  target : String
} derive(Debug)

///|
pub extend Target with @debug.Debug::{to_repr}

///|
/// 解析绝对 URL。相对地址与非 http(s)/socks5 协议抛 `Unsupported`：
/// 它们的共同点是「请求还没发出去就失败了」，正是这个分类的定义。
pub fn parse_target(url : String) -> Target raise @transport.TransportError {
  let scheme_end = match url.find("://") {
    Some(index) => index
    None =>
      raise @transport.TransportError::Unsupported(
        "地址不是绝对地址：" + url,
      )
  }
  let scheme = url[:scheme_end].to_owned().to_lower()
  let use_tls = match scheme {
    "http" => false
    "https" => true
    "socks5" => false
    _ =>
      raise @transport.TransportError::Unsupported(
        "只支持 http/https 协议：" + scheme,
      )
  }
  let rest = url[scheme_end + 3:]
  // 切不开路径时（例如 `https://host`）按 HTTP 约定补成 `/`
  let (authority, target) = match rest.find("/") {
    Some(index) => (rest[:index], rest[index:].to_owned())
    None => (rest, "/")
  }
  let (host, port) = split_authority(authority, default_port(scheme))
  { scheme, use_tls, host, port, target, }
}

///|
/// scheme 的默认端口（http 80 / https 443；socks5 也按 1080 记，
/// 它只出现在代理地址上）。
fn default_port(scheme : String) -> Int {
  match scheme {
    "https" => 443
    "socks5" => 1080
    _ => 80
  }
}

///|
/// 把 `host[:port]` 切开。端口段必须全是数字且在 1..=65535，否则抛
/// `Unsupported`——发不出去的地址，不值得建连去试。
///
/// IPv6 字面量只认方括号形式（`[::1]:8080` 或 `[::1]`）：切分只认**方括号外**
/// 的最后一个冒号，裸冒号形式与「host:port」天然冲突，也不在常见写法里。
fn split_authority(
  authority : StringView,
  default_port : Int,
) -> (String, Int) raise @transport.TransportError {
  if authority.length() == 0 {
    raise @transport.TransportError::Unsupported("地址缺少主机名")
  }
  // 找方括号之外的最后一个冒号（即 host:port 的分隔符）
  let mut colon : Int? = None
  let mut in_brackets = false
  for i in 0..<authority.length() {
    let code = authority.at(i).to_int()
    if code == 91 {
      // '['
      in_brackets = true
    } else if code == 93 {
      // ']'
      in_brackets = false
    } else if code == 58 && !in_brackets {
      // ':'
      colon = Some(i)
    }
  }
  match colon {
    None => (authority.to_owned(), default_port)
    Some(index) => {
      let port_part = authority[index + 1:]
      if port_part.length() == 0 {
        return (authority.to_owned(), default_port)
      }
      let mut port = 0
      for i in 0..<port_part.length() {
        let code = port_part.at(i).to_int()
        if code < 48 || code > 57 {
          raise @transport.TransportError::Unsupported(
            "端口不是数字：{authority}",
          )
        }
        port = port * 10 + (code - 48)
      }
      if port < 1 || port > 65535 {
        raise @transport.TransportError::Unsupported(
          "端口越界：{authority}",
        )
      }
      (authority[:index].to_owned(), port)
    }
  }
}

///|
/// `Host` 头的值：默认端口按 RFC 9112 §7.2 省略，非默认端口必须带上。
pub fn host_header(target : Target) -> String {
  let default = default_port(target.scheme)
  if target.port == default {
    target.host
  } else {
    "\{target.host}:\{target.port}"
  }
}
