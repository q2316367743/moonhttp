// ============================================================================
// response 包：读全量的响应值，对应 axios 的 `AxiosResponse`。
//
// 这一簇里只有 `Response` 一个类型，它刻意做到「两边都不认识」：
// - 不抛 `HttpError`——能拿到 `Response` 就说明 HTTP 这一层已经成功
//   （状态码校验在 `client` 包的管线上），解析失败抛的是 `@json.ParseError`；
// - 不认识 `Client`——它只是管线的产出物。
//
// 这两条让它能垫在整张依赖图的最底层业务包上：`ErrorInfo.response : Response?`
// 需要 `Response` 在 `http_error` 的下游；而真正抛 `HttpError` 的流式类型
// （`StreamResponse` / `SseStream`）因此待在 `client` 包，不在这里。
//
// 跨包构造入口只有一个 `Response::new`：`raw` 是私有字段，跨包写不了记录
// 字面量，`client` 包拼响应（正常路径、错误体、传输失败的现场）都走它。
//
// 读全量的语义：响应体字节已经在手，怎么读由三个方法决定
// （`bytes` / `text` / `json`），改写由五个 `with_*` 决定——它们是响应拦截器
// 的全部写回入口。
// ============================================================================

///|
/// 包内别名：裸名 `Config` / `Headers` 来自下面两个包
/// （根包会对使用者再导出它们，本包内部按裸名使用）。
using @config {type Config}

///|
using @headers {type Headers}

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
  status : Int32
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
/// 从「零件」拼出一份 `Response`——本包**唯一**的公开构造入口。
///
/// `raw` 是私有字段，跨包写不出记录字面量，所以拼响应的活只能落在本包：
/// `client` 包的三条路（读全量的正常路径、流式入口的错误体、传输失败时
/// 挂到错误上的现场）都经这里。
pub fn Response::new(
  status : Int32,
  status_text : String,
  headers : Headers,
  raw : Bytes,
  config : Config,
) -> Response {
  { status, status_text, headers, config, raw, }
}

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
pub fn Response::content_length(self : Response) -> Int32 {
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
// Response 的改写入口 —— 供响应拦截器使用
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
pub fn Response::with_status(self : Response, status : Int32) -> Response {
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
