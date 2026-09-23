// ============================================================================
// AGENTS.md RL-04 例外声明
//
// 本文件是根包的**实现层**：`Client` 及其三个入口（`request` / `stream` /
// `sse`），加上它们共用的纯函数管线。562 行，超过 RL-04 的 300 行上限，
// 按 RL-04 为「根包文件」开出的例外处理——上限 1000 行。
//
// 为什么入口与管线在同一个文件：管线里每个函数都只被这几个入口调用
//（`build_prepared_request` / `open_stream` 拼请求，`build_response` /
// `validate_response` 解响应），拆开只是多一次跳转。它们仍然全部是 `fn`
// （包私有），没有一个是公开 API——对外类型在 `facade.mbt`。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   1. Client 与它的入口   —— request / stream / sse
//   2. 请求构造            —— 地址、头、body 的纯函数
//   3. 响应解码            —— Content-Type 判定与 response_type 分支
//   4. 状态码校验          —— validate_status 判定与错误分档
// ============================================================================

// ---------------------------------------------------------------------------
// 1. Client 与它的入口 —— request / stream / sse
// ---------------------------------------------------------------------------

///|
/// HTTP 客户端实例，对应 axios 的 `AxiosInstance`。
///
/// 实例是不可变的：`create` 不修改自身，而是返回一个继承了当前默认值的新实例。
/// 这样多个实例之间不会互相影响，也就不会出现 axios 里
/// 「改了全局 `axios.defaults` 影响所有实例」那类隐蔽的相互干扰。
pub struct Client {
  /// 该实例的默认配置（已叠加在内置默认值之上）
  priv defaults : Config
  /// 传输层实现，决定「真的发出去」由谁完成
  priv transport : &@transport.Transport
}

///|
/// 创建实例。
///
/// - `config`：叠加在**内置默认值**之上的用户配置，
///   对应 axios 里 `axios.create(config)` 的语义（`axios.defaults` 的位置由
///   `@config.defaults()` 固定提供）；
/// - `transport`：传输层实现，缺省是真正走网络的 `AsyncHttpTransport`；
///   测试或特殊场景可以注入自己的实现（例如 `MockTransport`）。
pub fn Client::new(
  config? : Config,
  transport? : &@transport.Transport,
) -> Client {
  let defaults = match config {
    Some(config) => @merge.merge_config(@config.defaults(), config)
    None => @config.defaults()
  }
  let transport : &@transport.Transport = match transport {
    Some(transport) => transport
    None => @transport.AsyncHttpTransport::new()
  }
  { defaults, transport, }
}

///|
/// 基于当前实例派生一个新实例，对应 axios 的 `instance.create(config)`。
///
/// 新实例的默认值是「本实例的默认值」叠加 `config`，因此会继承父实例的
/// `base_url`、公共头等设置。注意 axios 的 `instance.create` 合并的是
/// 该实例自己的 defaults、与全局 defaults 无关，这里的行为一致。
pub fn Client::create(self : Client, config : Config) -> Client {
  {
    defaults: @merge.merge_config(self.defaults, config),
    transport: self.transport,
  }
}

///|
/// 本实例的默认配置。返回的是不可变值，修改它请用 `create` 派生。
pub fn Client::defaults(self : Client) -> Config {
  self.defaults
}

///|
/// 发送一次请求并返回响应；任何失败都抛出 `HttpError`。
///
/// 步骤与 axios 的 `_request` 一致：
/// 1. 合并配置（实例默认值在下、本次请求配置在上）；
/// 2. 确定请求方法；
/// 3. 拼接完整地址并追加 query、拍平头、序列化 body；
/// 4. 交给传输层发送，并把响应体读到 EOF（非流式路径要有完整内容才能解析）；
/// 5. 解析响应体、校验状态码。
///
/// 传输层的错误在这里被翻译成对外的 `ErrorCode`，
/// 所以调用方不需要认识 `moonbitlang/async` 的错误类型。
///
/// 不想读全响应体时用另外两个入口：大文件下载用 `Client::stream`（原始字节流），
/// SSE 用 `Client::sse`（事件流）。读不读、按什么单位读，由入口决定而不是配置。
pub async fn Client::request(
  self : Client,
  config : Config,
) -> Response raise HttpError {
  // 1. 合并配置
  let merged = @merge.merge_config(self.defaults, config)
  // 2. 方法缺省时先回退到实例默认值，再回退到 HTTP 的默认约定 GET
  let merged = {
    ..merged,
    http_method: Some(
      resolve_method(merged.http_method, self.defaults.http_method),
    ),
  }
  // 3. 地址、头、body
  let prepared = build_prepared_request(merged)
  // 4. 发送并把响应体读到 EOF——非流式路径要拿完整响应体做解析。
  //    读取也算在这一步：传输层交出来的是流，超时/断连可能发生在读取阶段。
  //    传输层错误在这里收敛成对外的分类，调用方无需认识底层错误类型。
  let (raw, body) = try {
    let raw = self.transport.send(prepared)
    (raw, raw.body.read_all())
  } catch {
    error => raise transport_error(error, merged)
  }
  // 5. 解析响应体，再校验状态码
  let response = build_response(raw, body, merged)
  validate_response(response)
  response
}

///|
/// 两个流式入口（`stream` / `sse`）共用的前半段：
/// 合并配置 → 定方法 → 拼地址与头 → 发送 → 校验状态码。
///
/// 状态码校验规则与 `request` 完全一致（默认只放行 2xx）。校验不通过时
/// 会把错误响应体读全（错误响应通常很短）再抛 `HttpError`——错误里仍然
/// 带着响应，状态码、响应头与错误原文都看得到。长连场景下这是唯一能
/// 立刻看到「为什么没连上」的地方，而不是一个裸状态码。
///
/// 与 `request` 的最后一步不同：这里**不读响应体**，把「还开着的连接」
/// 连同响应头一起返回，由调用方（两个流式入口）决定怎么读。
async fn Client::open_stream(
  self : Client,
  config : Config,
) -> (@transport.RawResponse, Config) raise HttpError {
  let merged = @merge.merge_config(self.defaults, config)
  let merged = {
    ..merged,
    http_method: Some(
      resolve_method(merged.http_method, self.defaults.http_method),
    ),
  }
  let prepared = build_prepared_request(merged)
  let raw = self.transport.send(prepared) catch {
    error => raise transport_error(error, merged)
  }
  if !status_allowed(raw.status, merged) {
    let body = raw.body.read_all() catch {
      error => raise transport_error(error, merged)
    }
    // 错误体不做 JSON 解析：格式不可预期，强行解析只会把状态码失败盖掉。
    let response = plain_response(raw, body, merged)
    raise status_error(response.status, merged, Some(response))
  }
  (raw, merged)
}

///|
/// 发起一次请求，但不读响应体，把**原始字节流**交给调用方。
///
/// 与 `request` 共用前半段（合并配置 → 定方法 → 拼地址/头/body → 发送 → 校验），
/// 区别是响应体不读：适合大文件下载、需要自己按块处理的场景。
/// 按 SSE 事件读请用 `Client::sse`——那是另一个协议，两个入口的类型也不同，
/// 免得把二进制数据喂进事件解析器（见 `facade.mbt` 里 `SseStream` 的说明）。
///
/// 拿到 `StreamResponse` 之后要负责读到 EOF 或调用 `close()`，
/// 否则这条连接不会释放。
pub async fn Client::stream(
  self : Client,
  config : Config,
) -> StreamResponse raise HttpError {
  let (raw, merged) = self.open_stream(config)
  {
    status: raw.status,
    status_text: raw.status_text,
    headers: raw.headers,
    config: merged,
    body: raw.body,
  }
}

///|
/// 发起一次 SSE 请求，把解析好的**事件流**交给调用方。
///
/// 与 `stream` 共用前半段，多一道准入检查：响应头必须声明
/// `Content-Type: text/event-stream`。不是就立刻关掉连接并报
/// `ErrorCode::NotSupported`——「拿到的不是 SSE 却按 SSE 读」是使用错误，
/// 让它响亮失败，比把 JSON 或二进制解成一堆莫名其妙的事件好得多。
/// 确实要接一个不声明类型的服务端，可以用 `Client::stream` + 公开的
/// `@moonhttp.SseParser` 自己驱动（那正是解析器独立成包的好处）。
///
/// 拿到 `SseStream` 之后要负责读到 EOF 或调用 `close()`，否则连接不会释放。
pub async fn Client::sse(
  self : Client,
  config : Config,
) -> SseStream raise HttpError {
  let (raw, merged) = self.open_stream(config)
  if !declares_event_stream(raw.headers) {
    // 连接已经建立，报错前必须先释放，否则漏一条 TCP 连接。
    raw.body.close()
    raise make_error(
      "响应没有声明 text/event-stream，不能用 Client::sse 按事件读；需要原始字节流请用 Client::stream",
      ErrorCode::NotSupported,
      merged,
      None,
    )
  }
  {
    status: raw.status,
    status_text: raw.status_text,
    headers: raw.headers,
    config: merged,
    body: raw.body,
    parser: @sse.SseParser::new(),
    closed: false,
  }
}

///|
/// 方法缺省时先回退到实例默认值，再回退到 HTTP 的默认约定 GET。
///
/// axios 在 `_request` 里也是从 `this.defaults.method` 单独回退一次，
/// 因为合并时 method 走的是「只取请求级」策略，实例默认值不在合并结果里。
fn resolve_method(
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
/// 创建实例的便捷入口，对应 `axios.create(config)`。
///
/// `config` 是位置参数（与 axios 的 `axios.create(config)` 一致），
/// 会叠加在内置默认值之上。不需要任何定制时用 `default_client()`；
/// 需要注入传输层（例如测试里换成 `MockTransport`）时用
/// `Client::new(config~, transport~)`。
pub fn create(config : Config) -> Client {
  Client::new(config~)
}

///|
/// 用内置默认值 + 真实传输层创建一个默认实例。
///
/// 与 axios 的全局 `axios` 不同，本模块没有可变的全局状态，
/// 所以这里是一个工厂函数而不是一个共享单例：
/// 想定制默认值请用 `create(...)` 创建，或从已有实例用 `client.create(...)` 派生。
pub fn default_client() -> Client {
  Client::new()
}
// ---------------------------------------------------------------------------
// 2. 请求构造 —— 地址、头、body 的纯函数
// ---------------------------------------------------------------------------

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
/// 不做 JSON 解析的响应对象：`data` 是原文、`raw` 是原始字节。
///
/// `Text` 模式、`Auto` 下的非 JSON 响应与解析失败都落在这里；
/// 流式路径读错误体时也用它——错误体的格式不可预期，
/// 强行解析只会把「状态码失败」这个更准确的原因盖掉。
fn plain_response(
  raw : @transport.RawResponse,
  body : Bytes,
  config : Config,
) -> Response {
  {
    data: Json::string(@utf8.decode_lossy(body)),
    status: raw.status,
    status_text: raw.status_text,
    headers: raw.headers,
    config,
    raw: body,
  }
}

///|
/// 把传输层错误翻译成对外的 `HttpError`。
///
/// 这层翻译的意义是：调用方不需要认识 `moonbitlang/async` 的错误类型，
/// 也不必知道底层用的是哪套 HTTP 实现。流式读取失败走的是同一条映射。
fn transport_error(
  error : @transport.TransportError,
  config : Config,
) -> HttpError {
  match error {
    @transport.TransportError::Timeout =>
      make_error("请求超时", ErrorCode::Timeout, config, None)
    @transport.TransportError::Network(message) =>
      make_error(
        "网络请求失败：" + message,
        ErrorCode::Network,
        config,
        None,
      )
    @transport.TransportError::Unsupported(message) =>
      make_error(
        "传输层不支持该请求：" + message,
        ErrorCode::NotSupported,
        config,
        None,
      )
  }
}

// ---------------------------------------------------------------------------
// 3. 响应解码 —— Content-Type 判定与 response_type 分支
// ---------------------------------------------------------------------------

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
/// 响应头里声明的媒体类型：`Content-Type` 去掉 `;` 之后的参数、去掉首尾空白、
/// 小写化。头缺失或值为空时返回 `None`（`Headers::get` 本就大小写不敏感）。
///
/// 只取「媒体类型本体」：`application/json; charset=utf-8` 与 `application/json`
/// 必须得到同一个判断结果。
fn media_type(headers : Headers) -> String? {
  let raw = match headers.get("Content-Type") {
    Some(value) => value
    None => return None
  }
  // 参数以第一个 `;` 为界，之后的 charset 之类与类型判定无关。
  let essence = match raw.find(";") {
    Some(index) => raw[:index]
    None => raw
  }
  let normalized = essence.trim().to_lower().to_owned()
  if normalized.is_empty() {
    None
  } else {
    Some(normalized)
  }
}

///|
/// 媒体类型是否表示 JSON：`application/json` 本体，或带结构化后缀的
/// `application/*+json`（`application/problem+json`、`application/vnd.api+json`
/// 这类）。
///
/// `text/json` 这种非标准写法不算：它不是注册过的类型，宁可不解析也不要猜。
fn is_json_media_type(media : String) -> Bool {
  media == "application/json" ||
  (media.has_prefix("application/") && media.has_suffix("+json"))
}

///|
/// `Auto` 模式下是否值得尝试 JSON 解析——由 `Content-Type` 决定。
///
/// 这道门槛是必需的：`123`、`true`、`"x"` 这些纯文本本身就是合法 JSON 文本，
/// 无脑解析会把 `text/plain` 的响应变成数字或布尔值。
///
/// 没有声明 `Content-Type` 时仍然尝试解析，保留 axios 的 `forcedJSONParsing`
/// 行为——很多服务端返回 JSON 却不带这个头，卡死它们得不偿失。
fn auto_parses_json(headers : Headers) -> Bool {
  match media_type(headers) {
    None => true
    Some(media) => is_json_media_type(media)
  }
}

///|
/// 响应头是否声明了 SSE（`text/event-stream`）。
///
/// 判定只有这一处：`StreamResponse::is_event_stream`（给原始流的调用方自查）
/// 与 `Client::sse`（入口处的准入检查）都走它，避免两处规则漂移。
fn declares_event_stream(headers : Headers) -> Bool {
  match media_type(headers) {
    Some(media) => media == "text/event-stream"
    None => false
  }
}

///|
/// 把原始响应按 `response_type` 解读成对外的响应对象。
///
/// 解析规则对齐 axios 的 `transformResponse`：
/// - `Auto`（默认）：**先看 `Content-Type`**——声明是 JSON（或压根没声明）才尝试
///   解析，解析失败把原文当字符串，**不报错**；声明是其它的（`text/*`、
///   `application/xml` 等）直接不解析；
/// - `Json`：忽略 `Content-Type` 强制解析，失败按 `ERR_BAD_RESPONSE` 报错；
/// - `Text`：完全不解析。
///
/// `Auto` 里的 `Content-Type` 判定见 `auto_parses_json`：`123` 这类纯文本
/// 本身是合法 JSON，不设这道门槛就会把 `text/plain` 的响应解成数字。
///
/// 强制 JSON 失败时，错误里会带上一个「data 为原文」的响应对象，
/// 让调用方仍能看到状态码与响应头，对应 axios 把 `response` 挂在错误上的做法。
/// `body` 由调用方读好传进来：传输层交出来的是响应体**流**，
/// 读全量这一步是调用方的选择（`request` 读全量，`stream` 不读）。
fn build_response(
  raw : @transport.RawResponse,
  body : Bytes,
  config : Config,
) -> Response raise HttpError {
  let text = @utf8.decode_lossy(body)
  let fallback = plain_response(raw, body, config)
  match config.response_type.unwrap_or(ResponseType::Auto) {
    Text => fallback
    // 强制解析：Content-Type 拦不住这里，声明了 text/html 也照解。
    Json =>
      match try_parse_json(text) {
        Some(data) => { ..fallback, data, }
        None =>
          raise make_error(
            "响应体不是合法 JSON，但 response_type 要求按 JSON 解析",
            ErrorCode::BadResponse,
            config,
            Some(fallback),
          )
      }
    Auto =>
      if auto_parses_json(raw.headers) {
        match try_parse_json(text) {
          Some(data) => { ..fallback, data, }
          None => fallback
        }
      } else {
        fallback
      }
  }
}

// ---------------------------------------------------------------------------
// 4. 状态码校验 —— validate_status 判定与错误分档
// ---------------------------------------------------------------------------

///|
/// 状态码是否被配置放行，对应 axios 的 `settle` 判定。
///
/// - `validate_status` 为 `None` 时一律放行（axios 里 `!validateStatus` 的效果）；
/// - 内置默认值是 `200 <= status < 300`，只认 2xx，
///   所以 3xx 也算失败——这与 axios 一致（它不把重定向当成功）。
///
/// 流式路径（`Client::stream`）复用这个判定：那时响应体还没读，
/// 不能先造出 `Response` 再校验。
fn status_allowed(status : Int, config : Config) -> Bool {
  match config.validate_status {
    None => true
    Some(validate) => validate(status)
  }
}

///|
/// 校验失败时按 axios 的分档给错误码：4xx → `BadRequest`，其余 → `BadResponse`
/// （axios 用 `[ERR_BAD_REQUEST, ERR_BAD_RESPONSE][floor(status/100) - 4]` 取到同一结果）。
fn status_error_code(status : Int) -> ErrorCode {
  if status >= 400 && status < 500 {
    ErrorCode::BadRequest
  } else {
    ErrorCode::BadResponse
  }
}

///|
/// 状态码不被放行时的统一错误。两条路径（读全量 / 流式）共用同一份文案与分档。
/// `response` 在流式路径下可能还没解析出来，此时传 `None`。
fn status_error(
  status : Int,
  config : Config,
  response : Response?,
) -> HttpError {
  make_error(
    "请求失败，状态码 " + status.to_string(),
    status_error_code(status),
    config,
    response,
  )
}

///|
/// 校验响应状态码；不通过就抛出带响应的错误。
fn validate_response(response : Response) -> Unit raise HttpError {
  if !status_allowed(response.status, response.config) {
    raise status_error(response.status, response.config, Some(response))
  }
}
