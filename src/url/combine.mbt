///|
/// 判断 `url` 是否为绝对地址，等价于 axios `isAbsoluteURL` 用的正则
/// `/^([a-z][a-z\d+\-.]*:)?\/\//i`：可选的 scheme（字母开头，其后为字母/数字/`+`/`-`/`.`）
/// 之后紧跟 `//`。
///
/// 三点容易踩坑：
/// - scheme 部分是可选的，所以 `//cdn.example.com/x` 这种「协议相对地址」
///   也算绝对地址，这与 axios 的注释一致；
/// - `localhost:8080/x` 不是绝对地址：它虽然含冒号，但 `:` 后面不是 `//`，
///   所以会正常地和 `base_url` 拼接；
/// - 协议相对地址必须先判 `//` 前缀：`//cdn.example.com:8080/x` 里也有冒号，
///   若先按冒号切 scheme 会把 `//cdn.example.com` 当成 scheme 而误判成相对地址
///   （axios 的正则里 scheme 可选，端口不影响判定）。
pub fn is_absolute_url(url : StringView) -> Bool {
  if url.has_prefix("//") {
    return true
  }
  match url.find(":") {
    Some(colon) => {
      let scheme = url[:colon]
      is_valid_scheme(scheme) && url[colon + 1:].has_prefix("//")
    }
    None => false
  }
}

///|
/// scheme 的文法校验：首字符必须是字母，其后是字母、数字或 `+` `-` `.`。
fn is_valid_scheme(scheme : StringView) -> Bool {
  if scheme.length() == 0 {
    return false
  }
  let mut first = true
  for c in scheme {
    let is_alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    let is_digit = c >= '0' && c <= '9'
    let ok = if first {
      is_alpha
    } else {
      is_alpha || is_digit || c == '+' || c == '-' || c == '.'
    }
    if !ok {
      return false
    }
    first = false
  }
  true
}

///|
/// 拼接 `base_url` 与相对路径，等价于 axios 的 `combineURLs`。
///
/// 规则：去掉 base 末尾的 `/`、去掉相对路径开头的 `/`，中间补恰好一个 `/`。
/// 与 axios 的唯一差异是：axios 用 `/\/?\/$/` 一次只吃掉最多两个尾斜杠，
/// 这里把所有尾斜杠都去掉，避免 `https://a///` 拼出 `https://a//x` 这类结果。
pub fn combine_urls(base_url : String, relative_url : String) -> String {
  // 相对路径为空时原样返回 base，与 axios 的 `relativeURL ? ... : baseURL` 一致。
  if relative_url.length() == 0 {
    return base_url
  }
  let base = base_url.trim_end(chars="/").to_owned()
  let relative = relative_url.trim_start(chars="/").to_owned()
  base + "/" + relative
}

///|
/// 计算请求的完整地址（还没拼 query），等价于 axios 的 `buildFullPath`。
///
/// 判定顺序与 axios 完全一致：
/// 1. `url` 是绝对地址且允许绝对地址 → 直接用 `url`
/// 2. 否则只要 `base_url` 存在 → 拼接
/// 3. 否则原样返回 `url`
///
/// `allow_absolute_urls` 为 `None` 时按 `true` 处理（axios 的默认值）。
/// `base_url` 为空串时按「不存在」处理，这与 axios 里 `if (baseURL && ...)`
/// 把空串当作 falsy 的行为一致。
pub fn build_full_path(
  base_url : String?,
  url : String?,
  allow_absolute_urls : Bool?,
) -> String? {
  let url = match url {
    None => return None
    Some(url) => url
  }
  let has_base_url = match base_url {
    Some(base_url) => base_url.length() > 0
    None => false
  }
  if !has_base_url {
    return Some(url)
  }
  let allow_absolute = allow_absolute_urls.unwrap_or(true)
  if !is_absolute_url(url) || !allow_absolute {
    // 相对地址，或者显式关掉了绝对地址直连（allow_absolute_urls = false）。
    Some(combine_urls(base_url.unwrap(), url))
  } else {
    Some(url)
  }
}
