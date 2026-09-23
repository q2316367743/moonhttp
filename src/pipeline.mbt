///|
/// 拼出 `Basic base64(username:password)`。
///
/// 用户名或密码只给了一半时，缺的那半按空串处理——
/// 这与 axios 直接把 `username + ':' + password` 交给 base64 的行为一致。
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
/// 3. 序列化请求体，并按需补 `Content-Type` 与 `Authorization`。
///
/// 补默认头一律用 `set_if_absent`：用户显式设置的同名头永远优先，
/// 否则自动补的 `Content-Type: application/json` 会盖掉用户写的表单类型。
fn build_prepared_request(
  config : Config,
) -> @transport.PreparedRequest raise HttpError {
  let url = match
    @url.build_full_path(
      config.base_url,
      config.url,
      config.allow_absolute_urls,
    ) {
    Some(url) => url
    None =>
      raise make_error(
        "请求缺少 url：请在配置里提供 url 或 base_url",
        ErrorCode::InvalidUrl,
        config,
        None,
      )
  }
  // query 在地址拼接完成之后追加，避免参数被当成路径的一部分。
  let url = @url.build_url(url, config.params)
  let meth = config.http_method.unwrap_or(Method::Get)
  let mut headers = @merge.flatten_headers(
    config.common_headers,
    config.method_headers,
    config.headers,
    meth,
  )
  let body = match config.data {
    None => None
    // 字符串按原文发送，且不推断 Content-Type：调用方可能就是想发一段
    // 纯文本或一段自己序列化好的载体。
    Some(Json::String(text)) => Some(@utf8.encode(text))
    Some(data) => {
      // 其它 Json 值按 axios 默认的 transformRequest 处理：序列化成 JSON 文本，
      // 并补上 Content-Type: application/json（不覆盖用户已设置的值）。
      headers = headers.set_if_absent("Content-Type", "application/json")
      Some(@utf8.encode(data.stringify()))
    }
  }
  let headers = match config.auth {
    // Basic 认证同样不覆盖用户自己设置的 Authorization。
    Some(auth) => headers.set_if_absent("Authorization", basic_auth(auth))
    None => headers
  }
  { http_method: meth, url, headers, body, timeout: config.timeout, }
}

///|
/// 尝试把响应文本按 JSON 解析；不是合法 JSON 时返回 `None`。
///
/// 「不是 JSON」在这里是一种正常结果而不是异常：默认的 `Auto` 模式
/// 就是靠它来决定「解析成功用对象、失败留原文」。
fn try_parse_json(text : String) -> Json? {
  let parsed = @json.parse(text) catch { _ => return None }
  Some(parsed)
}

///|
/// 把原始响应按 `response_type` 解读成对外的响应对象。
///
/// 解析规则对齐 axios 的 `transformResponse`：
/// - `Auto`（默认）：能解析成 JSON 就解析，失败则把原文当字符串，**不报错**；
/// - `Json`：强制解析，失败按 `ERR_BAD_RESPONSE` 报错；
/// - `Text`：完全不解析。
///
/// 强制 JSON 失败时，错误里会带上一个「data 为原文」的响应对象，
/// 让调用方仍能看到状态码与响应头，对应 axios 把 `response` 挂在错误上的做法。
fn build_response(
  raw : @transport.RawResponse,
  config : Config,
) -> Response raise HttpError {
  let text = @utf8.decode_lossy(raw.body)
  let fallback : Response = {
    data: Json::string(text),
    status: raw.status,
    status_text: raw.status_text,
    headers: raw.headers,
    config,
    raw: raw.body,
  }
  // 解析失败的判定统一在这里做一次，三条分支只是对结果的不同取舍。
  let parsed = try_parse_json(text)
  match config.response_type.unwrap_or(ResponseType::Auto) {
    Text => fallback
    Auto =>
      match parsed {
        Some(data) => { ..fallback, data, }
        None => fallback
      }
    Json =>
      match parsed {
        Some(data) => { ..fallback, data, }
        None =>
          raise make_error(
            "响应体不是合法 JSON，但 response_type 要求按 JSON 解析",
            ErrorCode::BadResponse,
            config,
            Some(fallback),
          )
      }
  }
}

///|
/// 状态码校验，对应 axios 的 `settle`。
///
/// - `validate_status` 为 `None` 时一律放行（axios 里 `!validateStatus` 的效果）；
/// - 内置默认值是 `200 <= status < 300`，只认 2xx，
///   所以 3xx 也算失败——这与 axios 一致（它不把重定向当成功）；
/// - 失败时按 axios 的分档给错误码：4xx → `BadRequest`，其余 → `BadResponse`
///   （axios 用 `[ERR_BAD_REQUEST, ERR_BAD_RESPONSE][floor(status/100) - 4]` 取到同一结果）。
fn validate_response(response : Response) -> Unit raise HttpError {
  match response.config.validate_status {
    None => ()
    Some(validate) =>
      if !validate(response.status) {
        let code = if response.status >= 400 && response.status < 500 {
          ErrorCode::BadRequest
        } else {
          ErrorCode::BadResponse
        }
        raise make_error(
          "请求失败，状态码 " + response.status.to_string(),
          code,
          response.config,
          Some(response),
        )
      }
  }
}
