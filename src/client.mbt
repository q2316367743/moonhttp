// ============================================================================
// AGENTS.md RL-04 例外声明
//
// 本文件是根包的**实现层**：`Client` 及其三个入口（`request` / `stream` /
// `sse`），加上它们共用的纯函数管线。614 行，超过 RL-04 的 300 行上限，
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
//   3. 响应构造            —— 按 response_encoding 解码响应体与 SSE 判定
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
/// 4. 交给传输层发送；
/// 5. 把响应体读到 EOF（读全量才有完整的 `data`）；
/// 6. 按 `response_encoding` 解码响应体、校验状态码。
///
/// 与 axios 的一处刻意差异：这里**不解析 JSON**。`Response::data` 是解码后的
/// 原文，要对象请自己对它调用 `@json.parse`——「猜内容类型」在静态类型下
/// 只会把错误推迟到调用方，而 `text/plain` 的 `123` 被解成数字那类静默错误
/// 比多写一行 `@json.parse` 贵得多。
///
/// 传输层的错误在这里被翻译成对外的 `ErrorCode`，
/// 所以调用方不需要认识 `moonbitlang/async` 的错误类型。
///
/// 失败不等于「什么都没收到」：响应头到手之后才失败的请求（读响应体的中途
/// 超时、连接被重置），错误里会带上**已经收到的响应**——状态行、响应头与
/// 读到的部分正文，从 `HttpError::response()` 取。连响应头都没到手时，
/// 错误里没有响应。
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
  // 4. 发送：这一步失败说明响应头还没到手，错误里没有响应可挂。
  let raw = self.transport.send(prepared) catch {
    error => raise transport_error(error, merged, None)
  }
  // 5. 把响应体读到 EOF——读全量才能解出完整的 `data`。读取阶段失败
  //    （超时、断连）时响应头早已到手，把状态行、响应头与**读到的部分**
  //    一起挂到错误上，失败现场才不会只剩一个错误码。
  let (body, failure) = raw.body.read_all_partial()
  match failure {
    Some(error) =>
      raise transport_error(
        error,
        merged,
        Some(
          build_response(raw.status, raw.status_text, raw.headers, body, merged),
        ),
      )
    None => ()
  }
  // 6. 按 response_encoding 解码响应体，再校验状态码
  let response = build_response(
    raw.status,
    raw.status_text,
    raw.headers,
    body,
    merged,
  )
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
/// 立刻看到「为什么没连上」的地方，而不是一个裸状态码；连读错误体都失败
/// （超时、断连）时，错误里带着已经读到的部分，状态码与响应头照样在。
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
    error => raise transport_error(error, merged, None)
  }
  if !status_allowed(raw.status, merged) {
    // 错误体也要读全；读到一半失败（超时、断连）时把已读到的部分挂到
    // 错误上——那部分通常正是服务端写下的原因，比一个光秃秃的超时有用。
    let (body, failure) = raw.body.read_all_partial()
    let response = build_response(
      raw.status,
      raw.status_text,
      raw.headers,
      body,
      merged,
    )
    match failure {
      Some(error) => raise transport_error(error, merged, Some(response))
      None => ()
    }
    // 错误体不做额外处理：按配置的编码解码成原文就交出去，不猜它「应该是什么格式」
    // ——错误体格式不可预期，强行解释只会把「状态码失败」这个更准确的原因盖掉。
    raise status_error(response.status, merged, response)
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
/// 这道检查失败时错误里挂着**已经收到的响应**（状态行与响应头），
/// 但不读响应体：声明了别的类型就可能是任意大小的二进制，要看原文请改走
/// `Client::stream`。
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
      Some(
        build_response(raw.status, raw.status_text, raw.headers, b"", merged),
      ),
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
/// 把传输层错误翻译成对外的 `HttpError`。
///
/// 这层翻译的意义是：调用方不需要认识 `moonbitlang/async` 的错误类型，
/// 也不必知道底层用的是哪套 HTTP 实现。流式读取失败走的是同一条映射。
///
/// `response` 是**失败前已经收到的响应**：传输层失败不等于「什么都没收到」
/// ——响应头到手之后才失败的请求，状态行、响应头与已经读到的字节都在手里
/// （`raw` 可能是半截的），把它们挂到错误上，失败现场才不会只剩一个错误码。
/// 失败发生在收到响应头之前（连不上、DNS 解析失败、请求还没发出去）时传
/// `None`——那时确实没有响应。
///
/// 错误码仍然是「失败本身」的分类（超时归 `Timeout`、断连归 `Network`），
/// 不会因为挂上了响应就改用状态码分档。
fn transport_error(
  error : @transport.TransportError,
  config : Config,
  response : Response?,
) -> HttpError {
  match error {
    @transport.TransportError::Timeout =>
      make_error("请求超时", ErrorCode::Timeout, config, response)
    @transport.TransportError::Network(message) =>
      make_error(
        "网络请求失败：" + message,
        ErrorCode::Network,
        config,
        response,
      )
    @transport.TransportError::Unsupported(message) =>
      make_error(
        "传输层不支持该请求：" + message,
        ErrorCode::NotSupported,
        config,
        response,
      )
  }
}

// ---------------------------------------------------------------------------
// 3. 响应构造 —— 按 response_encoding 解码响应体、拼成 Response
// ---------------------------------------------------------------------------

///|
/// 按配置的编码把响应体字节解成文本。
///
/// 解码一律是 lossy 的（core 的 `decode_lossy` 系列）：该编码下非法的字节
/// 解成替换字符 `U+FFFD` 而不是抛错。响应正文由服务端说了算，为了几个坏字节
/// 把整个响应判成失败得不偿失；要精确字节读 `Response::raw`。
///
/// 只有 `latin1` 是自己写的（core 没有）：ISO-8859-1 的码点就是字节值，
/// 一个循环就够。其余三种都直接调 core。
///
/// `response_encoding` 为 `None`（手写的 `Config` 没过内置默认值）时按 UTF-8
/// 处理，与 `defaults()` 里显式设的默认值一致。
fn decode_body(body : Bytes, encoding : ResponseEncoding) -> String {
  match encoding {
    Utf8 => @utf8.decode_lossy(body)
    Latin1 => {
      let buf = StringBuilder()
      for i in 0..<body.length() {
        buf.write_char(body[i].to_char())
      }
      buf.to_string()
    }
    Ascii => @ascii.decode_lossy(body)
    Utf16le => @utf16.decode_lossy(body, endianness=@utf16.Endian::Little)
  }
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
/// 把响应拼成对外的 `Response`：`data` 是按 `response_encoding` 解码的原文、
/// `raw` 是原始字节。
///
/// 三处共用它：
/// - `Client::request` 读全量后的正常路径；
/// - 流式路径读错误体（`open_stream` 状态码不通过时）；
/// - **传输层失败**——失败可能发生在响应头到手之后（读响应体的中途），
///   此时状态行、响应头与已读到的字节都在手里，拼成一份响应挂到错误上，
///   调用方才看得到「服务器到底回了什么、走到哪一步断的」。
///
/// 之所以按「零件」而不是一整份 `RawResponse` 取参数：流式类型
/// （`StreamResponse` / `SseStream`）读失败时手里只有状态行与响应头，
/// 没有 `RawResponse`。
fn build_response(
  status : Int,
  status_text : String,
  headers : Headers,
  body : Bytes,
  config : Config,
) -> Response {
  {
    data: decode_body(body, config.response_encoding.unwrap_or(Utf8)),
    status,
    status_text,
    headers,
    config,
    raw: body,
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
///
/// 响应是必有的：读全量路径此时已经解析出响应，流式路径也把错误体读完了
/// （哪怕只读到一部分，状态行与响应头一定在）。所以这里不收 `None`——
/// 「状态码失败」和「错误里带响应」是同一件事。
fn status_error(
  status : Int,
  config : Config,
  response : Response,
) -> HttpError {
  make_error(
    "请求失败，状态码 " + status.to_string(),
    status_error_code(status),
    config,
    Some(response),
  )
}

///|
/// 校验响应状态码；不通过就抛出带响应的错误。
fn validate_response(response : Response) -> Unit raise HttpError {
  if !status_allowed(response.status, response.config) {
    raise status_error(response.status, response.config, response)
  }
}
