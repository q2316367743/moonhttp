// ============================================================================
// AGENTS.md RL-04 例外声明
//
// 本文件是根包的**实现层**：`Client` 类型、它的三个入口（`request` / `stream` /
// `sse`），加上把 util 的纯函数结果拼成对外类型的两个函数。远超 RL-04 的 300 行
// 上限，按 RL-04 为「根包文件」开出的例外处理——上限 1000 行。
//
// 与它同目录的三个文件同属一个包，拆文件不影响依赖方向（见 `docs/01-architecture.md`）：
//   - `util/`   —— 纯逻辑：拼请求、解码、Content-Type 与状态码判定
//   - `http_error.mbt` —— 错误类型与抛错点
//   - `facade.mbt`     —— 对外响应类型与再导出
// 本文件剩下的 `fn` 都是包私有的，没有一个是公开 API。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   1. Client 与它的入口   —— request / stream / sse + 两个工厂
//   2. 接壤层              —— 拼请求、拼 Response
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
    Some(config) => @config.merge_config(@config.defaults(), config)
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
    defaults: @config.merge_config(self.defaults, config),
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
/// 5. 把响应体读到 EOF（读全量才有完整的响应体）；
/// 6. 校验状态码。
///
/// 与 axios 的一处刻意差异：这里**不解析 JSON、也不预先解码**。响应体以原始
/// 字节交出去，读法由调用方选：`Response::text()`（按 `response_encoding` 解码）、
/// `Response::bytes()`（精确字节）、`Response::json()`（解码后 `@json.parse`）。
/// 「猜内容类型」在静态类型下只会把错误推迟到调用方，而 `text/plain` 的 `123`
/// 被解成数字那类静默错误比多写一行 `@json.parse` 贵得多。
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
  let merged = @config.merge_config(self.defaults, config)
  // 2. 方法缺省时先回退到实例默认值，再回退到 HTTP 的默认约定 GET
  //    （`Config` 有私有字段，包外写不了记录展开，回填只能用构建器）
  let merged = merged.with_method(
    @util.resolve_method(merged.http_method, self.defaults.http_method),
  )
  // 3. 地址、头、body
  let prepared = prepare_request(merged)
  // 4. 发送：这一步失败说明响应头还没到手，错误里没有响应可挂。
  let raw = self.transport.send(prepared) catch {
    error => raise transport_error(error, merged, None)
  }
  // 5. 把响应体读到 EOF——读全量才有完整的响应体。读取阶段失败
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
  // 6. 校验状态码（解码不在这里：响应体以原始字节交出去，读法由调用方选）
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
  let merged = @config.merge_config(self.defaults, config)
  let merged = merged.with_method(
    @util.resolve_method(merged.http_method, self.defaults.http_method),
  )
  let prepared = prepare_request(merged)
  let raw = self.transport.send(prepared) catch {
    error => raise transport_error(error, merged, None)
  }
  if !@util.status_allowed(raw.status, merged) {
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
    // 错误体不做额外处理：响应体以原始字节交出，`HttpError::response()` 上
    // 拿到的 `Response` 自己按配置的编码解（`text()`），不猜它「应该是什么格式」
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
  if !@util.declares_event_stream(raw.headers) {
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
// 2. 接壤层 —— 把 util 的纯函数结果拼成对外类型与对外错误
//    （错误类型与传输层/状态码的抛错点在 http_error.mbt）
// ---------------------------------------------------------------------------

///|
/// 拼请求：调 `@util.build_prepared_request`，把「地址不可用」这唯一一种
/// 纯逻辑失败翻译成对外错误。
///
/// 为什么这层翻译要单独有个函数：纯函数用 `None` 表达失败（util 不认识
/// `HttpError`，也拿不到 `ErrorCode`），错误码与文案只能由根包决定。
/// `request` 与 `open_stream` 两条入口都走它，免得同一份文案写两遍。
fn prepare_request(
  config : Config,
) -> @transport.PreparedRequest raise HttpError {
  match @util.build_prepared_request(config) {
    Some(prepared) => prepared
    None =>
      raise make_error(
        "请求缺少 url：请在配置里提供 url 或 base_url",
        ErrorCode::InvalidUrl,
        config,
        None,
      )
  }
}

///|
/// 把响应拼成对外的 `Response`：只放**原始字节**进去，解码不在这里
/// ——读法由调用方经 `Response::text` / `bytes` / `json` 选（见 `facade.mbt`）。
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
  { status, status_text, headers, config, raw: body, }
}
