// ============================================================================
// AGENTS.md RL-04 例外声明
//
// 本文件是根包的**门面层**：对外暴露的数据类型与再导出集中在这里。
// 它超过 RL-04 的 300 行上限，按 RL-04 为「根包文件」开出的例外处理
// ——上限 1000 行，并在此声明。
//
// 这几个类型必须在根**包**（而不是像 `util` 那样独立成包）：它们互相引用，而且
// `Client` 要返回它们、`StreamResponse` / `SseStream` 要抛 `HttpError`。更硬的
// 一条是 `HttpError`——`pub using` **再导出不了错误构造子**，它一旦离开根包，
// `catch { @moonhttp.HttpError(info) }` 就写不出来了。实验证据与「为什么不能在
// 子包里安家」见 `docs/01-architecture.md`。
//
// 但**文件**怎么分是自由的：同目录 = 同包，拆文件不影响依赖方向，跨文件的
// `pub` / `priv` 照常可见。`HttpError` 与所有抛错点因此单独放在 `http_error.mbt`，
// 纯逻辑（拼请求、解码、Content-Type 与状态码判定）独立成 `util` 包。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   1. 再导出           —— pub using 各子包的类型
//   2. Response         —— 读全量得到的响应（含 2.1 的五个改写入口，供响应拦截器）
//   3. StreamResponse   —— 原始字节流响应（下载）
//   4. SseStream        —— 按事件读的 SSE 响应
// ============================================================================

// ---------------------------------------------------------------------------
// 1. 再导出 —— 各子包里有意义的类型
// ---------------------------------------------------------------------------

///|
/// 门面：把子包里对使用者有意义的类型从根包再导出一份。
///
/// 这样开发者只 import 一个 `@moonhttp` 就能拿到全部公开类型，
/// 不必记住每个类型归属哪个子包。子包结构本身仍然保留，
/// 需要精细控制的使用者（例如自己实现 `Transport`）可以直接依赖对应子包。
///
/// 约定：凡是出现在公开签名里的类型，都在定义它的包里再导出一次，
/// 因此各层之间不会出现「要用这个 API 却不知道类型该从哪 import」的情况。
/// 请求体的相关类型也一并再导出：`with_data_from_form` 的入参是 `FormData`，
/// `serialize_body` 的返回值是 `SerializedBody`，用它们不该再 import 一个 `@config`。
/// 进度回调的两个类型同理：`with_on_upload_progress` 的入参是 `ProgressCallback`。
pub using @config {
  type Config,
  type Method,
  type Auth,
  type Proxy,
  type ProxyProtocol,
  type ResponseEncoding,
  type FormData,
  type FormValue,
  type FormFile,
  type SerializedBody,
  type ProgressEvent,
  type ProgressCallback,
}

///|
pub using @headers {type Headers}

///|
/// SSE 解析器也再导出：它是独立的纯逻辑包，既能被 `Client::sse` 驱动，
/// 也能用在别的字节来源上（文件、WebSocket），是「服务端不声明
/// `text/event-stream` 时自己接」的公开逃生口。
pub using @sse {type SseEvent, type SseParser}

///|
/// 传输层抽象也一并再导出：自定义传输实现是公开的扩展点。
pub using @transport {trait Transport}

// ---------------------------------------------------------------------------
// 2. Response —— 读完的响应：字节在手，读法由调用方选
// ---------------------------------------------------------------------------

///|
/// 对外的响应对象，对应 axios 的 `AxiosResponse`。
///
/// **响应体只保留原始字节**（私有字段 `raw`），怎么读由三个方法决定：
/// - `bytes()`：原始字节，二进制内容或「想用别的编码自己解」走这里；
/// - `text()`：按 `config.response_encoding` 解码成文本（lossy）；
/// - `json()`：先按同一编码解成文本，再交给 `@json.parse`。
///
/// 这是与 axios 的一处刻意差异：axios 的 `res.data` 是 `any`，由 `responseType` /
/// `transformResponse` / `forcedJSONParsing` 猜出来；本项目不猜——没有「默认解码」
/// 这一说，读法摆在方法上。猜内容类型在静态类型下只会把错误推迟
/// （`text/plain` 的 `123` 被解成数字那类静默错误），多一次显式调用反而是更便宜的。
///
/// 字段私有是为了让「怎么读」只有一个落点：`raw` 一旦公开，调用方就会各自
/// 按自己的编码解一遍，`response_encoding` 这个配置项也就名存实亡了。
pub(all) struct Response {
  /// HTTP 状态码
  status : Int
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**），与 axios 的 `response.config` 一致
  config : Config
  /// 未经解码的原始响应体字节。读取入口是本类型的 `bytes` / `text` / `json`。
  priv raw : Bytes
} derive(Debug)

///|
pub extend Response with @debug.Debug::{to_repr}

///|
/// 原始响应字节，不做任何解码。
///
/// 需要精确字节、二进制内容（图片、压缩包），或想按另一种编码自己解时用它；
/// `content_length()` 数的也是这份字节。文本请用 `text()`。
pub fn Response::bytes(self : Response) -> Bytes {
  self.raw
}

///|
/// 按 `config.response_encoding` 把响应体解成文本（编码未设置时按 UTF-8，
/// 与 `defaults()` 里显式设的默认值一致）。
///
/// 解码一律 lossy：该编码下非法的字节解成替换字符 `U+FFFD`，**不抛错**
/// ——响应正文由服务端说了算，为了几个坏字节把整个响应判成失败得不偿失。
/// 需要精确字节读 `bytes()`。
///
/// 解码是按需做的：`Response` 里只有字节、不缓存文本，调几次就解几次。
/// 同一份响应要反复读文本时（例如在循环里），自己解一次存起来更划算。
pub fn Response::text(self : Response) -> String {
  @util.decode_body(self.raw, self.body_encoding())
}

///|
/// 把响应体当 JSON 解析：先按 `text()` 那套规则（`config.response_encoding`）
/// 解成文本，再交给 `@json.parse`（`Json` 是内建类型，不必 import 额外的东西）。
///
/// 解析失败抛的是 `@json.ParseError`（带出错位置），**不是 `HttpError`**——
/// 「HTTP 这一层出没出问题」与「正文是不是合法 JSON」是两类事：状态码不合规
/// 早在 `request` 里就抛过了，能拿到 `Response` 说明这一层已经成功；
/// 把解析错误混进 `HttpError` 只会让两边的分类都变模糊。不想处理解析错误的
/// 调用方用 `try! response.json()`，与手写 `try! @json.parse(response.text())` 等价。
///
/// 与 axios 的差别同样在这里：**只有显式调用才解析**，且不看 `Content-Type`
/// 猜——`123`、`true`、`"x"` 这些纯文本本身就是合法 JSON 文本，猜错的后果是
/// 静默的（文本被解成数字）。判断「这到底是不是 JSON」交给知道上下文的那一层。
pub fn Response::json(self : Response) -> Json raise @json.ParseError {
  @json.parse(self.text())
}

///|
/// 状态码是否落在 2xx。
///
/// 注意这与「请求是否成功」不是一回事：`request` 只在校验规则放行时才返回响应，
/// 所以能拿到 `Response` 通常已经表示成功；这个方法是给
/// 自定义了 `validate_status`（放行了 3xx/4xx）的场景用的。
pub fn Response::is_success(self : Response) -> Bool {
  self.status >= 200 && self.status < 300
}

///|
/// 响应体的字节长度，等价于 `bytes().length()`。
pub fn Response::content_length(self : Response) -> Int {
  self.raw.length()
}

///|
/// 响应体的编码：读（`text()` / `json()`）与写（`with_text` / `with_json`）
/// 共用同一个表达式，几处一旦漂移，写回的东西就与读回来的东西对不上。
/// `None` 时的 UTF-8 兜底与 `defaults()` 里显式设的默认值一致。
fn Response::body_encoding(self : Response) -> @config.ResponseEncoding {
  self.config.response_encoding.unwrap_or(Utf8)
}

// ---------------------------------------------------------------------------
// 2.1 Response 的改写入口 —— 供响应拦截器使用
//
// 响应拦截器拿到的 `Response` 必须是**能改的**，否则它就只是个旁观的日志钩子：
// 拆业务信封（`{ code, data }` → data）、把服务端写错的状态码归一、返回上一份
// 缓存的响应，都要经由这五个方法。五个都是「返回新响应」而非就地改
// （`Response` 与 `Config` 一样是不可变值）。
//
// 五个方法都**不改响应头**：`Content-Length` 是服务端写下的原文，本项目从不
// 改写它，所以换过 body 之后头与 `bytes().length()` 可能对不上——要一致就自己
// 用 `with_headers` 一起换。
//
// 写文本 / 写 JSON 的两个（`with_text` / `with_json`）按 `config.response_encoding`
// 编码，与 `text()` / `json()` 的读方向对称：`with_text(response.text())` 对四种
// 编码都是恒等的。要别的编码自己编好字节走 `with_body`。
// ---------------------------------------------------------------------------

///|
/// 换一个状态码，返回新响应。
///
/// 给响应拦截器用：把「HTTP 上是 200、业务上是失败」的响应改判，或者把服务端
/// 写错的状态码归一。`status_text` 不跟着变——它只是状态行的原文。
///
/// 改状态码**不会**重新跑状态码校验：`validate_status` 早在拦截器之前就跑完了，
/// 返回的响应原样交给调用方（要让它变成失败，请在拦截器里抛 `HttpError`）。
pub fn Response::with_status(self : Response, status : Int) -> Response {
  { ..self, status, }
}

///|
/// 换一组响应头，返回新响应。整体替换而不是合并——要合并先自己 merge。
pub fn Response::with_headers(self : Response, headers : Headers) -> Response {
  { ..self, headers, }
}

///|
/// 换一份响应体字节，返回新响应：`bytes()` / `text()` / `json()` /
/// `content_length()` 读到的都是新字节（解码才看 `response_encoding`）。
pub fn Response::with_body(self : Response, body : Bytes) -> Response {
  { ..self, raw: body, }
}

///|
/// 换一份响应体文本，返回新响应。编码按 `config.response_encoding`（未设置时
/// 按 UTF-8），与 `text()` 的读方向同一个编码——`with_text(response.text())`
/// 因此是恒等的，改写不会把非 UTF-8 的正文写坏（latin1 的 `é` 写回去还是
/// `0xE9`，详细理由见 `@util.encode_body`）。
///
/// 该编码装不下的码元写成一个 `?`（不抛错，与解码的 lossy 口径一致）。
/// 要精确字节、或要一份别的编码的正文，用 `with_body` 自己编。
pub fn Response::with_text(self : Response, body : String) -> Response {
  { ..self, raw: @util.encode_body(body, self.body_encoding()), }
}

///|
/// 换一份响应体**载荷**（`Json`），返回新响应：先 `stringify()` 成规范 JSON
/// 文本，再按 `config.response_encoding` 编成字节（与 `with_text` 同一口径）。
///
/// 这是「响应后处理」的写回入口，对应 axios 的 `transformResponse` 里那句
/// `res.data = ...`：解析用 `json()`，处理完用这个方法写回，调用方再读到的
/// 就是处理过的载荷。JSON 是静态类型下「任意数据」的落点，所以这一条比
/// `with_text` 更贴这种用法。
///
/// 两个语义要注意：
/// - 写回的是**载荷**，也就是一份 JSON 文档：`Json::String("x")` 写成 `"x"`
///   （带引号），不是裸的 `x`。要写原文用 `with_text`。
/// - `stringify()` 的输出是紧凑形式（无缩进、无多余空白），所以「只把正文规范化
///   一遍」也是它的合法用法。
pub fn Response::with_json(self : Response, data : Json) -> Response {
  { ..self, raw: @util.encode_body(data.stringify(), self.body_encoding()), }
}

// ---------------------------------------------------------------------------
// 3. StreamResponse —— 原始字节流响应（下载）
// ---------------------------------------------------------------------------

///|
/// 流式响应：状态行与响应头已经到手，响应体按需读取。
///
/// 这是**原始字节流**的入口（下载、边到边处理都走它）。按事件读 SSE
/// 是另一种协议，用 `Client::sse` 拿到的 `SseStream`——两边类型分开，
/// 「按块读」与「按事件读」各自只有一个入口，调错是编译错误而不是
/// 把二进制数据解成一堆无意义的事件。
///
/// 与 `Response` 的差别都由「响应体还没读」这一条派生出来：
/// - 没有 `text()` / `bytes()` / `json()`：字节还没读出来，读多少由调用方
///   经 `read_some` / `read_until` / `read_all` 决定（`Response` 是已经读完的那份）；
/// - 响应体可能无限长，`Response` 那条「读全量再交出去」的路在这里不成立；
/// - 读取随时可能失败：统一抛 `HttpError`，错误里带着**已经收到的响应**
///   （状态行与响应头一定在；`read_all` 读到一半失败时还有已读到的字节），
///   调用方不必认识传输层错误。
///
/// 状态码与响应头这些「不读 body 就能拿到」的信息与 `Response` 保持一致，
/// 所以拿到流之后可以先按状态码与 `Content-Type` 决定怎么读。
pub(all) struct StreamResponse {
  /// HTTP 状态码
  status : Int
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**），与 axios 的 `response.config` 一致
  config : Config
  /// 响应体流。字段私有：读取入口都在本类型的方法上，
  /// 这样错误才能统一映射成 `HttpError` 而不是把传输层错误漏出去。
  priv body : @transport.ResponseBody
} derive(Debug)

///|
pub extend StreamResponse with @debug.Debug::{to_repr}

///|
/// 状态码是否落在 2xx。
///
/// 与 `Response::is_success` 一样，是给自定义了 `validate_status`
/// （放行了 3xx/4xx）的场景用的：默认配置下能拿到响应就说明已经通过了校验。
pub fn StreamResponse::is_success(self : StreamResponse) -> Bool {
  self.status >= 200 && self.status < 300
}

///|
/// `Content-Type` 是否声明了 SSE（`text/event-stream`）。
///
/// 只做查询：这是给「已经拿到原始流、想知道对面到底是不是 SSE」的调用方自查用的。
/// 真按事件读请改用 `Client::sse`，它在入口处就用同一个判定做了准入检查。
pub fn StreamResponse::is_event_stream(self : StreamResponse) -> Bool {
  @util.declares_event_stream(self.headers)
}

///|
/// 读失败时的统一出口：把传输层错误翻译成 `HttpError`，并把**已经收到的响应**
/// （状态行、响应头，以及 `body` 传进来的字节）挂上去。
///
/// 为什么失败也要挂响应：响应头到手之后才可能开始读，所以失败时状态码与响应头
/// 必然已经存在，它们是回答「是在什么响应上断的」的唯一线索。
/// `body` 只有「读到一半失败、字节还没交出去」的场景（`read_all`）才有值；
/// 按块读失败时数据已经交给调用方了，传 `b""`。
fn StreamResponse::read_error(
  self : StreamResponse,
  error : @transport.TransportError,
  body : Bytes,
) -> HttpError {
  transport_error(
    error,
    self.config,
    Some(
      build_response(
        self.status,
        self.status_text,
        self.headers,
        body,
        self.config,
      ),
    ),
  )
}

///|
/// 读取一段响应体；到 EOF 返回 `None`，此时连接已经关闭。
///
/// 返回的块大小不保证（取决于对端一次发了多少数据），需要按边界切分的
/// 协议请用 `read_until`，不要自己假设一个块就是一条消息。
///
/// 读取失败（超时、断连）时抛 `HttpError`：错误码是传输层的分类，
/// 状态码与响应头挂在 `HttpError::response()` 上。
pub async fn StreamResponse::read_some(
  self : StreamResponse,
  max_len? : Int,
) -> Bytes? raise HttpError {
  try {
    match max_len {
      Some(limit) => self.body.read_some(max_len=limit)
      None => self.body.read_some()
    }
  } catch {
    // 失败前读到的字节已经交给调用方了，错误里只挂状态行与响应头。
    error => raise self.read_error(error, b"")
  }
}

///|
/// 读到分隔符 `sep` 为止，返回 `sep` 之前的内容（`sep` 被消费掉但不返回）。
///
/// 到 EOF 时把剩余内容当作最后一段返回，再读一次才返回 `None`。
///
/// **不要用它切 SSE 事件**：SSE 允许 CRLF / LF / CR 三种行尾，
/// 拿 `"\n\n"` 当分隔符在 CRLF 流上永远匹配不到（字节里没有连续两个 LF）。
/// 按事件读请改用 `Client::sse`（拿到的是 `SseStream`），
/// 它按规范处理三种行尾；这里刻意不提供事件读取的入口。
pub async fn StreamResponse::read_until(
  self : StreamResponse,
  sep : String,
) -> String? raise HttpError {
  self.body.read_until(sep) catch {
    error => raise self.read_error(error, b"")
  }
}

///|
/// 读到 EOF，返回剩下的全部字节，并关闭流。
///
/// 用于「先拿流判断状态码、再一次性取内容」的场景（例如下载）。
///
/// 中途失败时抛 `HttpError`，并且**已经读到的字节不会丢**：它们与状态行、
/// 响应头一起挂在错误的响应上（`HttpError::response()` 的 `bytes()` / `text()`）
/// ——下载断在 90% 时，这 90% 就是现场。
///
/// 配了 `on_download_progress` 时逐块报告进度（与 `Client::request` 同一条口径：
/// 凡「库读全量」都报告）。按块读的 `read_some` / `read_until` 不报告——
/// 那条路由调用方自己驱动，进度自己累加即可，见 `docs/10-progress.md`。
pub async fn StreamResponse::read_all(
  self : StreamResponse,
) -> Bytes raise HttpError {
  let on_progress = self.config.on_download_progress
  let (bytes, failure) = self.body.read_all_partial(on_progress?)
  match failure {
    Some(error) => raise self.read_error(error, bytes)
    None => bytes
  }
}

///|
/// 关闭响应体流并释放连接。幂等。
///
/// 只读了半截就停止（例如 SSE 收到想结束就断开）时必须显式调用，
/// 否则连接会一直挂着。
pub fn StreamResponse::close(self : StreamResponse) -> Unit {
  self.body.close()
}
// ---------------------------------------------------------------------------
// 4. SseStream —— 按事件读的 SSE 响应
// ---------------------------------------------------------------------------

///|
/// SSE 事件流：按事件读响应体，与 `StreamResponse`（原始字节流）分开。
///
/// **为什么不给 `StreamResponse` 加一个 `next_event`**：那个类型也是下载用的
/// 原始流，而二进制数据里 CR / LF 字节很常见，拿它喂事件解析器只会把字节流
/// 解成一堆无意义的东西（运气不好还会撞出几个假事件）。两个协议拆成两个类型，
/// 「按块读」与「按事件读」各自只有一个入口，调错是编译错误。
///
/// 拿到流时状态行与响应头就已经可用（SSE 靠这个先看状态码与 `Content-Type`）。
/// 连接生命周期与 `StreamResponse` 一致：读到 EOF 自动关闭，
/// 中途停止必须显式 `close()`。
pub(all) struct SseStream {
  /// HTTP 状态码
  status : Int
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**）
  config : Config
  /// 响应体流。字段私有：`next_event` 是唯一的读取入口，
  /// 这样错误才能统一映射成 `HttpError`，也不会有人绕过解析器去读字节。
  priv body : @transport.ResponseBody
  /// 事件解析器的状态
  priv parser : @sse.SseParser
  /// 调用方是否已经 `close()`。
  ///
  /// 单靠关掉 `body` 不够：一次读取可能已经把好几个事件解析进了解析器的队列，
  /// 关掉连接之后它们照样取得出来。`close` 的语义是「到此为止」，
  /// 与 `StreamResponse::close()` 之后 `read_some` 只返回 `None` 保持一致。
  priv mut closed : Bool
} derive(Debug)

///|
pub extend SseStream with @debug.Debug::{to_repr}

///|
/// 状态码是否落在 2xx。
///
/// 与 `Response::is_success` 同义，是给自定义了 `validate_status`
/// （放行了 3xx / 4xx）的场景用的：默认配置下能拿到流就说明已经通过了校验。
pub fn SseStream::is_success(self : SseStream) -> Bool {
  self.status >= 200 && self.status < 300
}

///|
/// 读失败时的统一出口：与 `StreamResponse::read_error` 同理，把已经收到的响应
/// （状态行 + 响应头）挂到错误上——长连断掉时，`status` 与响应头是唯一能说明
/// 「对面是谁、连接建到了哪一步」的信息。
///
/// 这里没有字节可挂：读进来的字节属于解析器，要么已经变成事件，要么还在它的
/// 缓冲里，都不该在错误里重复一遍。
fn SseStream::read_error(
  self : SseStream,
  error : @transport.TransportError,
) -> HttpError {
  transport_error(
    error,
    self.config,
    Some(
      build_response(
        self.status,
        self.status_text,
        self.headers,
        b"",
        self.config,
      ),
    ),
  )
}

///|
/// 读下一个事件；流结束返回 `None`。
///
/// 事件边界、字段语义（`event:` / `data:` / `id:` / `retry:`）、注释行、
/// 多行 `data:` 合并、三种行尾都由 `@sse.SseParser` 按 WHATWG 规范处理，
/// 调用方拿到的已经是解析好的事件。
///
/// 几条与规范一致的边界：
/// - 只发了 `id:` / `retry:` 或只有心跳注释的块**不产生事件**，会继续往下读；
/// - 流结束时没等到空行的事件**丢弃**，不会补发半个事件；
/// - `close()` 之后一律返回 `None`；
/// - `SseEvent` 上的 `id` / `retry` 是解析器的持久状态快照，
///   断线重连要用它们（本项目不自动重连，重连逻辑写在上层）。
///
/// 读取失败（超时、断连）时抛 `HttpError`：错误码是传输层的分类，
/// 状态码与响应头挂在 `HttpError::response()` 上。
pub async fn SseStream::next_event(
  self : SseStream,
) -> @sse.SseEvent? raise HttpError {
  // 已经关掉的流不再吐事件：解析器的队列里可能还存着已经解出来的事件，
  // 但 `close` 就是「到此为止」。
  if self.closed {
    return None
  }
  // 先取已解析好的（一次读进来的字节可能带来多个事件），没有再读一块喂进去。
  let mut event = self.parser.next()
  while event is None {
    let chunk = self.body.read_some() catch {
      error => raise self.read_error(error)
    }
    match chunk {
      None => {
        // EOF：让解析器处理末尾那个卡住的 CR，之后丢弃未完成的事件。
        self.parser.finish()
        return self.parser.next()
      }
      Some(bytes) => {
        self.parser.push(bytes)
        event = self.parser.next()
      }
    }
  }
  event
}

///|
/// 关闭响应体流并释放连接。幂等。
///
/// 读了几个事件就不想读了（例如任务结束）时必须显式调用，否则连接会一直挂着。
/// 关闭之后 `next_event` 一律返回 `None`——包括那一次读取里已经解析好、
/// 还排在解析器队列里的事件。与 `StreamResponse::close()` 的语义一致：
/// `close` 就是「到此为止」，不是「释放连接但还能接着读」。
pub fn SseStream::close(self : SseStream) -> Unit {
  self.closed = true
  self.body.close()
}
