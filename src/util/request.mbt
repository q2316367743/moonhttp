// util 包的**请求侧**纯函数：方法回退、Basic 认证串、把合并好的配置加工成
// 一份可以直接发送的请求。全部不碰网络、不碰 async，也不构造门面类型。

///|
/// 门面：签名里用到的类型再导出一次，本包与只 import `@util` 的使用者都能写裸名
/// （与 `merge` / `transport` 的做法一致）。
pub using @config {
  type Config,
  type Method,
  type Auth,
  type ResponseEncoding,
  type Proxy,
  type ProxyProtocol,
}

///|
pub using @headers {type Headers}

///|
/// 方法缺省时先回退到实例默认值，再回退到 HTTP 的默认约定 GET。
///
/// axios 在 `_request` 里也是从 `this.defaults.method` 单独回退一次，
/// 因为合并时 method 走的是「只取请求级」策略，实例默认值不在合并结果里。
pub fn resolve_method(
  request_level : Method?,
  instance_default : Method?,
) -> Method {
  match request_level {
    Some(meth) => meth
    None =>
      match instance_default {
        Some(meth) => meth
        None => Method::Get
      }
  }
}

///|
/// 拼出 `Basic base64(username:password)`。
///
/// 用户名或密码只给了一半时，缺的那半按空串处理——
/// 这与 axios 直接把 `username + ':' + password` 交给 base64 的行为一致。
///
/// 目标服务器的 `Authorization` 与代理的 `Proxy-Authorization` 都用它：
/// 两者都是同一套 RFC 7617 Basic 编码，差别只在落在哪个请求上。
fn basic_auth(auth : Auth) -> String {
  let username = auth.username.unwrap_or("")
  let password = auth.password.unwrap_or("")
  "Basic " + @base64.encode(@utf8.encode(username + ":" + password))
}

///|
/// 把代理配置拼成传输层要的形态：`协议://host[:port]` 与 CONNECT 的凭据值。
///
/// 端口缺省时**不写端口**，由底层按协议补默认值（http 80 / https 443）：
/// 在这里补一次等于把「协议 → 端口」的约定抄第二遍，抄错了会产生与底层
/// 不一致的行为，而这个约定本来只属于底层。
///
/// `host` 在调用方已经用 `Proxy::is_usable` 判过，这里的 `unwrap_or("")`
/// 只为保持函数全定义：真走到空 host 会拼出一个非法地址，底层报错，
/// 而不是静默直连（这正是要做校验的原因）。
fn proxy_endpoint(
  proxy : Proxy,
  authorization : String?,
) -> @transport.ProxyEndpoint {
  let scheme = proxy.protocol.unwrap_or(ProxyProtocol::Http).to_string()
  let mut authority = proxy.host.unwrap_or("")
  match proxy.port {
    Some(port) => authority = authority + ":" + port.to_string()
    None => ()
  }
  { url: scheme + "://" + authority, authorization, }
}

///|
/// 把已经合并好的配置加工成一份可以直接发送的请求（纯数据变换，没有 IO）。
///
/// 这里承担四件事，顺序与 axios 一致：
/// 1. `base_url` + `url` 拼成完整地址，再追加序列化后的 query；
/// 2. 把三层头（common < 按方法 < 请求级平铺）拍平成一份；
/// 3. 取请求体字节（`Config::serialize_body`，序列化在 config 包内完成），
///    并按需补 `Content-Type` 与 `Authorization`；
/// 4. 有代理时把 `Proxy-Authorization` 挪到 CONNECT 上（见下）。
///
/// 补默认头一律用 `set_if_absent`：用户显式设置的同名头永远优先，
/// 否则自动补的 `Content-Type: application/json` 会盖掉用户写的表单类型。
///
/// **代理凭据不进目标请求头。** 代理的 `auth` 按 axios 的规则设置
/// `Proxy-Authorization` 并覆写用户在头里自定义的同名值；两条路径的最终取值
/// 都落在 `PreparedRequest::proxy` 上（由传输层用于 CONNECT 握手），
/// 目标请求头里的 `Proxy-Authorization` 一律取走——代理凭据发给目标服务器
/// 既无用又是泄漏，`redirect.mbt` 同样把它当敏感头对待。
///
/// 两类输入返回 `None`（本包不认识 `HttpError`，把「错误码该是哪个、
/// 文案怎么写」留给根包——与 `@url.build_full_path` 的分工相同）：
/// 地址不可用（缺 `url` 且缺 `base_url`，或 `url` 非法），
/// 以及**配了代理却没给 host**（判定见 `Proxy::is_usable`）。
pub fn build_prepared_request(config : Config) -> @transport.PreparedRequest? {
  // 配了代理却没给 host：这份配置发不出去。宁可让调用方报错，也不能当成
  // 「没配代理」——那会让本该走代理的请求静默直连出去。
  match config.proxy {
    Some(proxy) if !proxy.is_usable() => return None
    _ => ()
  }
  let url = match
    @url.build_full_path(
      config.base_url,
      config.url,
      config.allow_absolute_urls,
    ) {
    Some(url) => url
    None => return None
  }
  // query 在地址拼接完成之后追加，避免参数被当成路径的一部分。
  let url = @url.build_url(url, config.params)
  let meth = config.http_method.unwrap_or(Method::Get)
  let mut headers = @config.flatten_headers(
    config.common_headers,
    config.method_headers,
    config.headers,
    meth,
  )
  // 请求体的字节与建议的 Content-Type 由 config 包产出（`Config::serialize_body`）：
  // body 的四种形态（原样文本 / JSON / 表单 / urlencoded）只有 config 包认识，
  // 这里只负责把建议的类型落到头上，仍是「补默认值」而非覆盖用户显式设置。
  let serialized = config.serialize_body()
  let body = serialized.bytes
  match serialized.content_type {
    Some(content_type) =>
      headers = headers.set_if_absent("Content-Type", content_type)
    None => ()
  }
  let headers = match config.auth {
    // Basic 认证同样不覆盖用户自己设置的 Authorization。
    Some(auth) => headers.set_if_absent("Authorization", basic_auth(auth))
    None => headers
  }
  // 代理凭据：先取走自定义的 `Proxy-Authorization`（它本来就该发给代理而不是
  // 目标服务器），再让 `proxy.auth` 覆写它——两手都空则是匿名代理。
  let (headers, proxy) = match config.proxy {
    Some(proxy) => {
      let custom = headers.get("Proxy-Authorization")
      let headers = headers.remove("Proxy-Authorization")
      let authorization = match proxy.auth {
        Some(auth) => Some(basic_auth(auth))
        None => custom
      }
      (headers, Some(proxy_endpoint(proxy, authorization)))
    }
    None => (headers, None)
  }
  Some({
    http_method: meth,
    url,
    headers,
    body,
    timeout: config.timeout,
    proxy,
  })
}
