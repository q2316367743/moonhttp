// ============================================================================
// AGENTS.md RL-04 例外声明
//
// 本文件是根包的**实现层**：`Client` 类型、它的三个入口（`request` / `stream` /
// `sse`），加上把 util 的纯函数结果拼成对外类型的两个函数。远超 RL-04 的 300 行
// 上限，按 RL-04 为「根包文件」开出的例外处理——上限 1000 行。
//
// 与它同目录的四个文件同属一个包，拆文件不影响依赖方向（见 `docs/01-architecture.md`）：
//   - `util/`          —— 纯逻辑：拼请求、解码、Content-Type 与状态码判定
//   - `http_error.mbt` —— 错误类型与抛错点
//   - `facade.mbt`     —— 对外响应类型与再导出
//   - `interceptors.mbt` —— 拦截器链与两条错误链（本文件在管线的两端调用它）
// 本文件剩下的 `fn` 都是包私有的，没有一个是公开 API。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   1. Client 与它的入口   —— request / stream / sse + 两个工厂
//   2. 接壤层              —— 合并配置、派发一次请求（请求链在它之前、状态码校验
//                             与响应链在它之后）、拼请求、拼 Response
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
  /// 拦截器链，对应 axios 实例上的 `interceptors`（见 `interceptors.mbt`）
  priv interceptors : Interceptors
  /// cookie 存储罐；`None` 表示不做任何 cookie 自动维护（行为与从前一致）。
  /// 只能在 `new` 时传入（与信号不进 Config 同理：它是有状态的运行时对象，
  /// 不是逐请求合并的配置）；`create` 派生的实例与父实例共享**同一个** jar
  /// （与拦截器链的继承口径一致，见 `docs/19-cookies.md`）。
  priv cookie_jar : @cookie.CookieJar?
}

///|
/// 创建实例。
///
/// - `config`：叠加在**内置默认值**之上的用户配置，
///   对应 axios 里 `axios.create(config)` 的语义（`axios.defaults` 的位置由
///   `@config.defaults()` 固定提供）；
/// - `transport`：传输层实现，缺省是真正走网络的自研栈 `HttpConnTransport`
///   （HTTP/1.0/1.1，RFC 净室实现，见 `docs/17-http-protocol.md` / `docs/18`）；
///   测试或特殊场景可以注入自己的实现（例如 `MockTransport`）；
/// - `interceptors`：请求 / 响应拦截器，缺省是一条都不挂（`Interceptors::new()`）；
/// - `cookie_jar`：cookie 存储罐，缺省不挂（不做 cookie 维护）。传入后
///   请求按 URL 自动携带、响应自动存取、过期自动失效（`docs/19-cookies.md`）。
pub fn Client::new(
  config? : Config,
  transport? : &@transport.Transport,
  interceptors? : Interceptors,
  cookie_jar? : @cookie.CookieJar,
) -> Client {
  let defaults = match config {
    Some(config) => @config.merge_config(@config.defaults(), config)
    None => @config.defaults()
  }
  let transport : &@transport.Transport = match transport {
    Some(transport) => transport
    // 缺省传输 = 自研 HTTP/1.1 栈（docs/17 第 1 期落地后的默认路径）
    None => @httpconn.HttpConnTransport::new()
  }
  let interceptors = match interceptors {
    Some(interceptors) => interceptors
    None => Interceptors::new()
  }
  { defaults, transport, interceptors, cookie_jar, }
}

///|
/// 基于当前实例派生一个新实例，对应 axios 的 `instance.create(config)`。
///
/// 新实例的默认值是「本实例的默认值」叠加 `config`，因此会继承父实例的
/// `base_url`、公共头等设置。注意 axios 的 `instance.create` 合并的是
/// 该实例自己的 defaults、与全局 defaults 无关，这里的行为一致。
///
/// **拦截器与 cookie 罐也继承**：派生实例与父实例用同一份链、同一个 jar。
/// 与 axios 不同（`axios.create()` 造出来的是没有拦截器的新实例），这里选
/// 继承——`create` 在本项目是「同一个实例换套默认值」，而换一套默认值就该
/// 照样带上认证头、日志这些横切逻辑，也不该丢掉登录攒下来的会话状态。
/// 确实要不带拦截器（或换一个空 cookie 罐）的实例，用 `Client::new(config~)`
/// 新造一个。
pub fn Client::create(self : Client, config : Config) -> Client {
  {
    defaults: @config.merge_config(self.defaults, config),
    transport: self.transport,
    interceptors: self.interceptors,
    cookie_jar: self.cookie_jar,
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
/// 3. 请求拦截器：**后注册先跑**，拿到的就是第 2 步的最终配置；
/// 4. 拼接完整地址并追加 query、拍平头、序列化 body；
/// 5. 交给传输层发送，需要时自动跟随重定向（最多 `max_redirects` 跳）；
/// 6. 把响应体读到 EOF（读全量才有完整的响应体）；
/// 7. 校验状态码；
/// 8. 响应拦截器：**先注册先跑**，正常路径改响应、错误路径救错或重试。
///
/// 失败按来源分流到两条错误链（这是与 axios 的 promise 链**有意不同**的一处，
/// 理由见 `docs/11-interceptors.md`）：
/// - 第 1~6 步的失败——被请求拦截器拦下、配置拼不出请求、连不上、超时、被取消、
///   重定向超限、读响应体失败——交给**请求侧**错误处理器，它可以返回一个响应把
///   这次失败救回来；
/// - 第 7 步的失败（状态码没通过校验）交给**响应侧**错误处理器，错误里带着完整
///   响应，重试、降级、改写成统一形状都写在那里。
///
/// 拦截器与重定向的相对位置是关键：整条重定向链只跑**一次**拦截器
/// （axios 的适配器内部跟随重定向，拦截器在它上层，两边一致）。理由与「为什么
/// 不把拦截器做成传输层中间件」见 `docs/11-interceptors.md`。
///
/// 重定向默认跟随：`max_redirects` 缺省是 5（axios 请求配置文档里的默认值），
/// 3xx 且带 `Location` 时自动跟过去，下一跳的地址 / 方法 / body / 凭据怎么变
/// 见 `@config.Config::next_redirect`（规则对齐 follow-redirects）。
/// 跟到超限抛 `ErrorCode::TooManyRedirects`；把上限设成 0 则完全不跟随，
/// 3xx 原样落到状态码校验手里。
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
/// 错误里没有响应。两类失败都会先经过请求侧的错误处理器（重试的落点）。
///
/// 取消信号由 `signal?` 参数给（对应 axios 的 `signal`），**不属于配置**：
/// 请求进入管线前信号已经取消时什么都不做，进行中的取消会打断挂起的连接动作，
/// 对外是一个 `ERR_CANCELED` 错误、可以用 `HttpError::is_cancelled()` 认出来。
/// 信号是一次性的，只能按请求传——放进实例默认值会拖垮这个实例之后的所有请求，
/// 所以 `Config` 里没有这个字段（设计理由见 `docs/12-cancellation.md`）。
///
/// 不想读全响应体时用另外两个入口：大文件下载用 `Client::stream`（原始字节流），
/// SSE 用 `Client::sse`（事件流）。读不读、按什么单位读，由入口决定而不是配置；
/// 它们**只过请求拦截器**：响应侧链与请求侧错误处理器都不跑——两者要交出去的
/// 都是一份 `Response`，而这两个入口手里是还没读的字节流，救回没有落点。
pub async fn Client::request(
  self : Client,
  config : Config,
  signal? : AbortSignal,
) -> Response raise HttpError {
  // 1~7. 请求阶段：合并配置 → 取消预检查 → 请求拦截器 → 派发（发送、跟重定向、
  //      读全量、拼响应）。这一段里出的任何错都算**请求阶段的失败**，收进 `stage`
  //      交给请求侧错误处理器；拿回来的响应这时还没校验状态码。
  let stage : Result[Response, HttpError] = try {
    // 1、2. 合并配置、定方法；紧接着做取消预检查：信号在请求进入管线之前就已
    //      取消时，这次请求**什么都不做**——不发任何 I/O，也不跑请求拦截器
    //      （拦截器可能带副作用）。检查放在这一层而不是只放在传输层，是为了让
    //      「取消」的语义与传输实现无关：Mock 传输层没有可中断的 I/O，但
    //      「已取消的信号让请求立刻失败」照样成立。
    let merged = self.merged_config(config)
    check_cancelled(merged, signal)
    // 3. 请求拦截器。被拦下时这次请求不发出，错误交给请求侧错误处理器
    //    ——所以这里不抛错，交给下面的分支收口。
    match self.interceptors.run_request(merged) {
      Err(error) => Err(error)
      // 4~7. 发送、跟重定向、读全量、拼响应（状态码校验不在这里）
      Ok(config) => Ok(self.dispatch_request(config, signal))
    }
  } catch {
    error => Err(error)
  }
  match stage {
    // 请求阶段的失败：请求侧错误处理器（返回响应 = 就地救回，否则抛出）
    Err(error) => self.interceptors.run_request_errors(error)
    // 8. 响应阶段：状态码校验；9. 响应拦截器（正常路径改响应，错误路径救错 / 重试）
    Ok(response) => self.interceptors.run_response(validate_response(response))
  }
}

///|
/// 合并配置并定下请求方法：三个入口共用的前两步。
///
/// 方法缺省时先回退到实例默认值，再回退到 HTTP 的默认约定 GET
/// （`Config` 有私有字段，包外写不了记录展开，回填只能用构建器）。
fn Client::merged_config(self : Client, config : Config) -> Config {
  let merged = @config.merge_config(self.defaults, config)
  merged.with_method(
    @util.resolve_method(merged.http_method, self.defaults.http_method),
  )
}

///|
/// 取消预检查：入口传进来的信号已经取消时让请求在进入管线前就失败。
///
/// 三个入口的调用点都紧跟在配置合并之后、请求拦截器之前，所以被取消的请求
/// 连拦截器都不会跑。它管的是「取消发生在请求发出**之前**」这一种情况
/// （包括拿一个已取消的信号来发请求、以及同一个信号被复用多次的情形）；
/// 「取消发生在请求进行中」由传输层的取消作用域负责（`docs/12-cancellation.md`）。
///
/// 信号从**入口参数**进来（`signal?`），不在配置里：信号是一次性的，
/// 放进实例默认值会让这个实例之后的所有请求一起失效——这条在类型上就不成立
/// （`Config` 没有这个字段），设计理由见 `docs/12-cancellation.md`。
///
/// 这里也是 `AbortError` 与本项目错误体系**唯一的接壤处**：abort 包不能引用
/// 本包的 `HttpError`，所以 `throw_if_aborted` 抛它自己的类型；这里接住并翻成
/// 统一的取消失败（`http_error.mbt` 的 `abort_error`）。使用者因此只会看到一种
/// 错误类型，`is_cancelled()` 照样认得出来。
fn check_cancelled(
  config : Config,
  signal : AbortSignal?,
) -> Unit raise HttpError {
  match signal {
    Some(signal) =>
      signal.throw_if_aborted() catch {
        @abort.AbortError::Aborted(reason) => raise abort_error(config, reason)
      }
    None => ()
  }
}

///|
/// 发送一次请求并把响应读全：拼地址 / 头 / body → 发送（含自动跟随重定向）
/// → 读全量 → 拼 `Response`。位置对应 axios 的 `dispatchRequest`。
///
/// 进来的配置必须是**已经过请求拦截器**的（`Client::request` 负责把请求链摆在
/// 它之前），本函数只管「发」。**不校验状态码**：校验留在 `Client::request` 里，
/// 这样「请求阶段的失败」与「状态码失败」才能分流到两条错误链。
async fn Client::dispatch_request(
  self : Client,
  merged : Config,
  signal : AbortSignal?,
) -> Response raise HttpError {
  // 拼地址 / 头 / body 并发送，中间需要跟随重定向时自动跟。
  // 拿回来的是**最后一跳**的响应与产出它的配置。
  // `buffered: true` 告诉拼请求那一层：「这次的响应体会被库读全」，
  // 于是由库来声明压缩、也由库来解压（见 docs/15-response-compression.md）。
  let (raw, merged) = self.send_following_redirects(merged, signal, true)
  // 把响应体读到 EOF——读全量才有完整的响应体。读取阶段失败
  // （超时、断连）时响应头早已到手，把状态行、响应头与**读到的部分**
  // 一起挂到错误上，失败现场才不会只剩一个错误码。
  // 配了 `on_download_progress` 时逐块报告：这是「库读全量」的两条路之一
  // （另一条是 `StreamResponse::read_all`），按块读的路不报告，见 docs/10-progress.md。
  // 读取中途失败时进度停在断点——已经报出去的字节数就是现场。
  let on_progress = merged.on_download_progress
  let (body, failure) = raw.body.read_all_partial(on_progress?)
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
  // 响应体解压：缓冲路径由库负责（见 `docs/15-response-compression.md`）。
  // 解压失败不在这里抛：状态码同样没通过校验时，状态码那个原因更准确
  // （404 的错误页解不开，说「404」比说「解压失败」有用）。
  match
    decode_response_body(raw.status, raw.status_text, raw.headers, body, merged) {
    Ok((decoded, headers)) =>
      // 校验状态码**不在这里**：交给 `Client::request`——那里才知道这次失败该走
      // 请求侧还是响应侧的错误处理器（字符集解码同样不在这里：响应体以原始字节
      // 交出去，读法由调用方选）
      build_response(raw.status, raw.status_text, headers, decoded, merged)
    Err(error) =>
      if @util.status_allowed(raw.status, merged) {
        raise error
      } else {
        // 状态码本身也没通过校验：以状态码为准，响应体与响应头都保持原样
        // ——字节确实还是压缩字节，`Content-Encoding` 也照原样留着（头与体一致）。
        build_response(raw.status, raw.status_text, raw.headers, body, merged)
      }
  }
}

///|
/// 两个流式入口（`stream` / `sse`）共用的前半段：
/// 合并配置 → 定方法 → 请求拦截器 → 拼地址与头 → 发送（含自动跟随重定向）
/// → 校验状态码。
///
/// 请求拦截器的位置与 `request` 一致（**后注册先跑**）；差别是被拦下时直接抛错，
/// 而不是交给响应侧错误处理器——两个流式入口没有响应侧链。
///
/// 重定向的处理与 `request` 完全一致（同一段循环，连上限与错误都一样）：
/// 跟到 3xx 的最后一跳为止，交出去的 `config` 也是**最后一跳**的配置。
///
/// 状态码校验规则与 `request` 完全一致（默认只放行 2xx）。校验不通过时
/// 会把错误响应体读全（错误响应通常很短）再抛 `HttpError`——错误里仍然
/// 带着响应，状态码、响应头与错误原文都看得到。长连场景下这是唯一能
/// 立刻看到「为什么没连上」的地方，而不是一个裸状态码；连读错误体都失败
/// （超时、断连）时，错误里带着已经读到的部分，状态码与响应头照样在。
///
/// 与 `request` 的最后一步不同：这里**不读响应体**，把「还开着的连接」
/// 连同响应头一起返回，由调用方（两个流式入口）决定怎么读。
///
/// 压缩声明按流式路径的规则走（`buffered: false`）：默认不声明，由底层实现补上
/// 并在响应头声明 gzip 时透明解压；关掉解压时声明 `identity` 挡住它。
async fn Client::open_stream(
  self : Client,
  config : Config,
  signal : AbortSignal?,
) -> (@transport.RawResponse, Config) raise HttpError {
  // 取消预检查的位置与 `request` 一致：合并配置之后、请求拦截器之前。
  // 两个流式入口共用这一条，所以 `stream` / `sse` 也被它覆盖。
  let merged = self.merged_config(config)
  check_cancelled(merged, signal)
  let merged = match self.interceptors.run_request(merged) {
    Ok(config) => config
    Err(error) => raise error
  }
  let (raw, merged) = self.send_following_redirects(merged, signal, false)
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
  signal? : AbortSignal,
) -> StreamResponse raise HttpError {
  let (raw, merged) = self.open_stream(config, signal)
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
  signal? : AbortSignal,
) -> SseStream raise HttpError {
  let (raw, merged) = self.open_stream(config, signal)
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
//    以及「发送 + 跟随重定向」那段编排（错误类型与抛错点在 http_error.mbt）
// ---------------------------------------------------------------------------

///|
/// 这次请求往 `Accept-Encoding` 上声明什么（`None` = 不声明，交给传输实现决定）。
///
/// 一句话版规则：**谁解压谁声明**，谁都不解压时用 `identity` 把压缩挡住。
/// - 缓冲路径（`Client::request`）：响应体由库读全、也由库解压，所以由库声明
///   `gzip, identity`；
/// - 流式路径（`stream` / `sse`）：流式解压由底层实现透明完成——它见请求里没有
///   `Accept-Encoding` 就会自己补上并在响应头声明 gzip 时解压，所以这里不声明，
///   把决定权留给它（见 `docs/15-response-compression.md`）；
/// - `decompress: false`：谁都不解压，于是声明 `identity` 让服务端别压缩
///   （也让底层不介入）。
///
/// 用户自己设置过 `Accept-Encoding` 时这段声明不生效（补默认头走
/// `set_if_absent`，见 `@util.build_prepared_request`）：流式路径那时交出去的就是
/// 压缩字节（头也留着，自描述）；缓冲路径是例外——它的承诺是「交出去的体一定解压」，
/// 所以只要响应头声明 gzip，读到的全量字节照样解（`decode_response_body`），
/// 无论那次声明是谁写的。
fn declared_encoding(config : Config, buffered : Bool) -> String? {
  if config.decompress.unwrap_or(true) {
    if buffered {
      Some("gzip, identity")
    } else {
      None
    }
  } else {
    Some("identity")
  }
}

///|
/// 拼请求：调 `@util.build_prepared_request`，把「这份配置拼不出可发送的请求」
/// 翻译成对外错误。
///
/// 为什么这层翻译要单独有个函数：纯函数用 `None` 表达失败（util 不认识
/// `HttpError`，也拿不到 `ErrorCode`），错误码与文案只能由根包决定。
/// `request` 与 `open_stream` 两条入口都走它，免得同一份文案写两遍。
///
/// 两种失败原因分别报：**代理配置缺 host** 与**请求缺 url**。
/// 两者都是 `ERR_INVALID_URL`（都属于「地址不可用」），但修法完全不同，
/// 文案上不能混为一谈——代理那条判在调 util 之前，正是为了能分开说。
fn prepare_request(
  config : Config,
  signal : AbortSignal?,
  buffered : Bool,
) -> @transport.PreparedRequest raise HttpError {
  match config.proxy {
    Some(proxy) if !proxy.is_usable() =>
      raise make_error(
        "代理配置缺少 host：请用 with_proxy 给出代理服务器地址",
        ErrorCode::InvalidUrl,
        config,
        None,
      )
    _ => ()
  }
  let accept_encoding = declared_encoding(config, buffered)
  match @util.build_prepared_request(config, signal?, accept_encoding?) {
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
/// 把响应体按响应头解压（目前只认 gzip），返回解压后的字节与处理过的响应头。
///
/// 只有缓冲路径（`Client::request`）用得到它：流式路径的响应体由底层透明解压，
/// 不走这里，见 `docs/15-response-compression.md`。
///
/// 三种「不解压、原样返回」：响应头没声明 gzip、`decompress: false`、
/// 以及空体——HEAD 这类响应可能带着 `Content-Encoding` 却一个字节都没有，
/// 硬解只会换来一个假失败（声明的是别的编码同样不解：`br` / `deflate` /
/// 多值都没有对应的解码器，假装认识比不认更危险）。
///
/// 解压成功后摘掉 `Content-Encoding` 与 `Content-Length`：这两个头描述的是**线上
/// 字节**，而交出去的响应体已经是实体字节，留着就等于让头与体互相矛盾
/// （底层透明解压时同样会删掉 `Content-Length`，两处口径一致）。
///
/// 解压失败返回 `Err` 而**不在这里抛**：状态码同样没通过校验时，状态码那个原因
/// 更准确（404 的错误页解不开，说「404」比说「解压失败」有用），由调用方
/// 结合校验结果决定报哪个。失败时错误里挂着**原始压缩字节与原始响应头**
/// ——解不开的就是这份字节，头照原样留着才看得出它声称自己是 gzip。
async fn decode_response_body(
  status : Int,
  status_text : String,
  headers : Headers,
  body : Bytes,
  config : Config,
) -> Result[(Bytes, Headers), HttpError] noraise {
  let needed = config.decompress.unwrap_or(true) &&
    @transport.declares_gzip(headers) &&
    body.length() > 0
  if !needed {
    return Ok((body, headers))
  }
  let decoded : Result[Bytes, @transport.TransportError] = Ok(
    @transport.decode_gzip(body),
  ) catch {
    error => Err(error)
  }
  match decoded {
    Ok(decoded) =>
      Ok((decoded, headers.remove("Content-Encoding").remove("Content-Length")))
    Err(error) =>
      Err(
        transport_error(
          error,
          config,
          Some(build_response(status, status_text, headers, body, config)),
        ),
      )
  }
}

///|
/// 挂了 cookie 罐时按请求 URL 算出该带的 `Cookie` 头并**补**到请求上。
///
/// 走 `set_if_absent`：用户（或请求拦截器）显式设置的 `Cookie` 头永远优先，
/// 与 Content-Type / Authorization / Accept-Encoding 的补默认头口径一致。
/// 没挂罐、或 jar 认为这跳没有该带的 cookie 时原样返回。
fn Client::attach_cookie(
  self : Client,
  prepared : @transport.PreparedRequest,
) -> @transport.PreparedRequest {
  match self.cookie_jar {
    None => prepared
    Some(jar) =>
      match jar.cookie_header(prepared.url) {
        None => prepared
        Some(value) =>
          {
            ..prepared,
            headers: prepared.headers.set_if_absent("Cookie", value),
          }
      }
  }
}

///|
/// 把一跳响应里的 Set-Cookie 全量喂给 cookie 罐（没挂罐时什么都不做）。
///
/// 放在**每跳 `send` 返回之后**：响应头到手即可入库，不必等响应体读完——
/// 登录流的中途 3xx 一样会种 cookie，读体失败也不该丢掉已到手的会话状态。
fn Client::capture_cookies(
  self : Client,
  url : String,
  set_cookies : Array[String],
) -> Unit {
  match self.cookie_jar {
    None => ()
    Some(jar) =>
      for set_cookie in set_cookies {
        jar.store(url, set_cookie)
      }
  }
}

///|
/// 发送一次请求，需要时自动跟随重定向；返回**最后一跳**的原始响应与产出它的配置。
///
/// 拦截器**不在**这一层：本函数每跟随一跳就调一次 `transport.send`，把拦截器
/// 挂进来会让它每跳重跑一遍（认证头重复注入、重试被放大成「跳数 × 重试次数」）。
/// 两段拦截器因此都落在本函数之外，整条重定向链只跑一次，见 `docs/11-interceptors.md`。
///
/// 分工：跟不跟、下一跳长什么样是纯逻辑（`@config.Config::next_redirect`，
/// 规则对齐 follow-redirects）；这里只做那层做不到的四件事：
/// 1. **计数与上限**：最多跟 `max_redirects` 跳，第 `max_redirects + 1` 个
///    重定向就抛 `TooManyRedirects`；
/// 2. **释放连接**：跟随之前先关掉 3xx 的响应体——那段正文不要了，留着不读
///    会漏一条没人管的连接（等价 follow-redirects 的 `response.destroy()`）；
/// 3. **每跳的错误现场**：传输失败时用**这一跳**的配置翻译错误，
///    与单跳时的规则一致；
/// 4. **每跳的 cookie**：挂了 cookie 罐时，发出前按这一跳的 URL 注入
///    `Cookie`（显式头优先），返回后把这一跳的 `Set-Cookie` 入库——跨域
///    重定向时 jar 按域匹配自然不再携带旧域的 cookie，与 `next_redirect`
///    剥显式 Cookie 头的规则互补（见 `docs/19-cookies.md`）。
///
/// `max_redirects <= 0` 时完全不跟随：3xx 原样返回，由状态码校验判定成败
/// ——与 axios 的 `maxRedirects: 0` 一致（那种配置下它连 follow-redirects 都不进）。
///
/// 上限未设置时按 5 兜底：内置默认值里本来就有它，正常路径上合并结果总是 `Some`；
/// 这里的兜底是留给「绕过 `defaults()` 直接用 util 层」的调用方的，
/// 数值取 axios 请求配置文档里的默认值 5。
///
/// 与 axios 的一处有意不同：每一跳各自受 `timeout` 约束（与既有的「建连到响应头
/// 整体一个时限、响应体每次读取一个时限」口径一致），所以整条链的最坏耗时是
/// 「上限 × timeout」；axios 是整条链共用一个计时器。
///
/// `buffered` 只用来决定请求头上的压缩声明（每跳都要重新拼请求，所以每跳都带上）：
/// 值为 `true` 表示这次调用的响应体会被库读全，因此由库声明、也由库解压，
/// 见 `declared_encoding` 与 `docs/15-response-compression.md`。
async fn Client::send_following_redirects(
  self : Client,
  merged : Config,
  signal : AbortSignal?,
  buffered : Bool,
) -> (@transport.RawResponse, Config) raise HttpError {
  let limit = merged.max_redirects.unwrap_or(5)
  let mut config = merged
  let mut prepared = self.attach_cookie(
    prepare_request(config, signal, buffered),
  )
  // 发送：这一步失败说明响应头还没到手，错误里没有响应可挂。
  let mut raw = self.transport.send(prepared) catch {
    error => raise transport_error(error, config, None)
  }
  self.capture_cookies(prepared.url, raw.set_cookies)
  // 不跟随：3xx 原样交出去（默认的 2xx 校验会把它判成失败）。
  if limit <= 0 {
    return (raw, config)
  }
  let mut followed = 0
  // 循环条件写成变量而不是 `while true`：函数要返回最后那一跳的响应与配置，
  // 用条件退出才能让出口只有末尾那一处。
  let mut following = true
  while following {
    match
      config.next_redirect(
        prepared.url,
        raw.status,
        raw.headers.get("Location"),
      ) {
      // 不是重定向（非 3xx / 没有 Location / Location 解析不出地址）就跟完了。
      None => following = false
      Some(next) => {
        // 预算用完了重定向又来了一个：把最后这个 3xx 挂到错误上再抛。
        if followed >= limit {
          let (body, _failure) = raw.body.read_all_partial()
          raise too_many_redirects_error(
            limit,
            config,
            Some(
              build_response(
                raw.status,
                raw.status_text,
                raw.headers,
                body,
                config,
              ),
            ),
          )
        }
        // 先释放这一跳的连接再发下一跳，否则每跟一次都漏一条连接。
        raw.body.close()
        followed = followed + 1
        config = next
        // 信号跟着每一跳走：取消落在两跳之间时，由传输层进入作用域时那次
        // `aborted()` 检查挡住（见 `docs/12-cancellation.md` 的「两条兜底」）。
        prepared = self.attach_cookie(prepare_request(config, signal, buffered))
        raw = self.transport.send(prepared) catch {
          error => raise transport_error(error, config, None)
        }
        self.capture_cookies(prepared.url, raw.set_cookies)
      }
    }
  }
  (raw, config)
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
