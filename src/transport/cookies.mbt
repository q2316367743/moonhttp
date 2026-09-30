// 旧栈（moonbitlang/async）的 Set-Cookie 出口。
//
// 底层把响应 cookie 解析好放在 `@http.Response::cookies` 里，
// 单值的 `response.headers` Map 中根本没有 Set-Cookie——所以旧栈要给
// `RawResponse::set_cookies` 补全量，只能从这里序列化回来。
//
// 保真度说明：这里拿到的**不是线上原文**，是底层 `Cookie::parse` 的产物，
// 序列化按字段重组、不保证属性顺序与原文一致，扩展属性也可能丢失。
// cookie jar 只消费 name / value 与过期 / 归属属性，这层差异对它不可见；
// 需要逐字节原文的场景（例如字符串断言的测试）请用自研栈 `HttpConnTransport`
// ——那边是原文透传。

///|
/// 把底层解析好的 cookie 列表还原成 Set-Cookie 头值数组（保序）。
fn serialize_cookies(cookies : Array[@http.Cookie]) -> Array[String] {
  let result : Array[String] = []
  for cookie in cookies {
    let mut line = cookie.name + "=" + cookie.value
    match cookie.domain {
      Some(domain) => line = line + "; Domain=" + domain
      None => ()
    }
    match cookie.path {
      Some(path) => line = line + "; Path=" + path
      None => ()
    }
    match cookie.expires_raw {
      Some(expires) => line = line + "; Expires=" + expires
      None => ()
    }
    match cookie.max_age {
      Some(max_age) => line = line + "; Max-Age=" + max_age.to_string()
      None => ()
    }
    if cookie.secure {
      line = line + "; Secure"
    }
    if cookie.http_only {
      line = line + "; HttpOnly"
    }
    for extension in cookie.extensions {
      line = line + "; " + extension
    }
    result.push(line)
  }
  result
}
