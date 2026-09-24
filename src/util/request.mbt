// util 包的**请求侧**纯函数：方法回退、Basic 认证串、把合并好的配置加工成
// 一份可以直接发送的请求。全部不碰网络、不碰 async，也不构造门面类型。

///|
/// 门面：签名里用到的类型再导出一次，本包与只 import `@util` 的使用者都能写裸名
/// （与 `merge` / `transport` 的做法一致）。
pub using @config {type Config, type Method, type Auth, type ResponseEncoding}

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
/// 只有 `build_prepared_request` 用它，所以不导出。
fn basic_auth(auth : Auth) -> String {
  let username = auth.username.unwrap_or("")
  let password = auth.password.unwrap_or("")
  "Basic " + @base64.encode(@utf8.encode(username + ":" + password))
}

///|
/// 把已经合并好的配置加工成一份可以直接发送的请求（纯数据变换，没有 IO）。
///
/// 这里承担三件事，顺序与 axios 一致：
/// 1. `base_url` + `url` 拼成完整地址，再追加序列化后的 query；
/// 2. 把三层头（common < 按方法 < 请求级平铺）拍平成一份；
/// 3. 取请求体字节（`Config::serialize_body`，序列化在 config 包内完成），
///    并按需补 `Content-Type` 与 `Authorization`。
///
/// 补默认头一律用 `set_if_absent`：用户显式设置的同名头永远优先，
/// 否则自动补的 `Content-Type: application/json` 会盖掉用户写的表单类型。
///
/// 地址不可用（缺 `url` 且缺 `base_url`，或 `url` 非法）时返回 `None`：
/// 本包不认识 `HttpError`，把「错误码该是 `InvalidUrl`、文案怎么写」留给根包
/// ——与 `@url.build_full_path` 的分工相同。
pub fn build_prepared_request(config : Config) -> @transport.PreparedRequest? {
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
  Some({ http_method: meth, url, headers, body, timeout: config.timeout, })
}
