// ============================================================================
// 错误构造：所有「什么情况下造 HttpError、造一个什么样的」都在这里，
// 全部是包私有函数——`http_error` 包是纯契约（类型与访问器），
// 「构造错误」是编排层的行为，所以落在这一侧。本文件因此依赖
// transport（翻译传输层错误）与 util（状态码校验规则），而 http_error 不用。
//
// 分区（顺序无关）：
//   统一构造    —— make_error（所有构造点的唯一落点）
//   传输层翻译  —— transport_error / cancelled_error / abort_error
//   状态码分档  —— status_error_code / status_error
//   重定向      —— too_many_redirects_error / stream_replay_error
//   校验        —— validate_response
// ============================================================================

// ---------------------------------------------------------------------------
// 统一构造
// ---------------------------------------------------------------------------

///|
/// 统一构造 `HttpError`，避免每处都手写一遍 `ErrorInfo`。
/// 调用点用 `raise make_error(...)` 抛出。
///
/// 构造器写类型限定的形式（`HttpError::HttpError(...)`）：`using` 的包内别名
/// 只带进类型名，构造器不跟着走（与根包 `pub using` 的限制同源，
/// 实测见 docs/01-architecture.md）。
fn make_error(
  message : String,
  code : ErrorCode,
  config : Config,
  response : Response?,
) -> HttpError {
  HttpError::HttpError(ErrorInfo::{ message, code, config, response, })
}

// ---------------------------------------------------------------------------
// 传输层翻译
// ---------------------------------------------------------------------------

///|
/// 把传输层错误翻译成对外的 `HttpError`。
///
/// 这层翻译的意义是：调用方不需要认识 `moonbitlang/async` 的错误类型，
/// 也不必知道底层用的是哪套 HTTP 实现。流式读取失败走的是同一条映射。
///
/// `response` 是**失败前已经收到的响应**：传输层失败不等于「什么都没收到」
/// ——响应头到手之后才失败的请求，状态行、响应头与已经读到的字节都在手里
/// （`bytes()` / `text()` 拿到的可能是半截），把它们挂到错误上，失败现场
/// 才不会只剩一个错误码。
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
    // 响应体声称的编码解不开（目前只有 gzip）：这不是网络故障，而是这份响应
    // 本身读不出来，所以归 `BadResponse` 而不是 `Network`。原始字节留在
    // `response` 上——「解不开」这个事实比「字节被吞掉」有用得多。
    @transport.TransportError::Malformed(message) =>
      make_error(
        "响应体解压失败：" + message,
        ErrorCode::BadResponse,
        config,
        response,
      )
    @transport.TransportError::Cancelled(reason) =>
      cancelled_error(config, reason, response)
  }
}

///|
/// 取消引起的失败：消息取取消理由，没给理由就用默认文案。
///
/// 两个入口共用它——传输层报 `TransportError::Cancelled(reason)` 时（取消落在某段
/// I/O 上；理由随错误一起上来，因为信号不在配置里、上层无从自己去找），以及上层
/// 进入管线时的预检查（入口传进来的信号在请求发出**之前**已经取消）。
/// 放在一起是为了让「取消长什么样」只有一份定义。
///
/// `response` 沿用「失败时带上已经收到的响应」那条规则：取消发生在响应头
/// 到手之后时，状态行、响应头与已读到的字节照样挂上（与超时、断连一致）；
/// 请求还没发出去就取消时是 `None`。
fn cancelled_error(
  config : Config,
  reason : String?,
  response : Response?,
) -> HttpError {
  make_error(cancelled_message(reason), ErrorCode::Cancelled, config, response)
}

///|
/// 把 abort 包在边界上抛出的 `AbortError` 归一成同一种取消失败（`ERR_CANCELED`）。
///
/// 唯一的调用点是本包 `client.mbt` 的取消预检查：abort 包是叶子，不认识任何
/// HTTP 错误类型，所以 `throw_if_aborted` 抛它自己的类型，由这里在接壤处翻成
/// 统一错误——使用者因此只会看到一种错误类型。载荷就是抛出时的 `signal.reason()`。
///
/// 错误里没有响应：预检查发生在任何 I/O 之前，这时确实一个字节都没发出去。
fn abort_error(config : Config, reason : String?) -> HttpError {
  cancelled_error(config, reason, None)
}

///|
/// 取消理由 → 错误文案：没给理由就用默认文案。
///
/// 信号自己不编文案（`abort` 包里没有「请求已取消」这句话），文案只在本文件一处。
fn cancelled_message(reason : String?) -> String {
  match reason {
    Some(reason) => reason
    None => "请求已取消"
  }
}

// ---------------------------------------------------------------------------
// 状态码分档
// ---------------------------------------------------------------------------

///|
/// 校验失败时按 axios 的分档给错误码：4xx → `BadRequest`，其余 → `BadResponse`
/// （axios 用 `[ERR_BAD_REQUEST, ERR_BAD_RESPONSE][floor(status/100) - 4]` 取到同一结果）。
fn status_error_code(status : Int32) -> ErrorCode {
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
  status : Int32,
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

// ---------------------------------------------------------------------------
// 重定向
// ---------------------------------------------------------------------------

///|
/// 重定向次数超过上限时的统一错误（`send_following_redirects` 的循环里抛）。
///
/// `response` 是**最后那个 3xx 响应**：读到它时说明重定向又来了一个，
/// 只是预算已经用完。按本项目「失败时带上已经收到的响应」的规则
/// （见 docs/README.md 的同步清单第 8 条）把它挂上——跟到第几跳、
/// 对面给的 `Location` 是什么，正是排查重定向成环最需要的信息。
/// 这一点与 axios 不同：axios 的这个错误里没有响应（follow-redirects
/// 在跟随下一跳前就把 3xx 响应 destroy 掉了），差异见 docs/08-redirects.md。
fn too_many_redirects_error(
  max_redirects : Int32,
  config : Config,
  response : Response?,
) -> HttpError {
  make_error(
    "重定向次数超过上限：max_redirects = " + max_redirects.to_string(),
    ErrorCode::TooManyRedirects,
    config,
    response,
  )
}

///|
/// 流式请求体遇上了「要原样重发请求体」的重定向（`send_following_redirects`
/// 的循环里抛，docs/20）。
///
/// 只有 307/308、以及 301/302 上保持方法的跳转会走到这里——303 与
/// 301/302 上的 POST 会降级成 GET 并丢掉 body，那条路不需要重放。
/// 流在首跳写完就耗尽，重放只会静默发出空体，宁可在这里明确报错
/// （fetch 对 stream body + redirect 的处理就是直接失败，同一口径）。
/// 错误分类用 `NotSupported`：这是「用了传输层没法满足的能力」，
/// 不是网络故障。`response` 是那个 3xx，按「失败带上已收到的响应」
/// 的规则挂上（与 `too_many_redirects_error` 同一做法）。
fn stream_replay_error(
  status : Int32,
  config : Config,
  response : Response?,
) -> HttpError {
  make_error(
    "流式请求体无法跟随状态码 " +
    status.to_string() +
    " 的重定向：它要求原样重发请求体，而读取流已在首跳写完耗尽",
    ErrorCode::NotSupported,
    config,
    response,
  )
}

// ---------------------------------------------------------------------------
// 校验
// ---------------------------------------------------------------------------

///|
/// 校验响应状态码：通过就把响应交出去，不通过就给出带响应的错误。
///
/// 返回 `Result` 而不是抛错：这个结果**就是**响应侧链的输入——`Client::request`
/// 拿到它直接交给 `Interceptors::run_response`，于是「状态码失败」与「请求阶段的
/// 失败」在调用点一眼分得开（后者走请求侧错误处理器，见 `docs/11-interceptors.md`）。
fn validate_response(response : Response) -> Result[Response, HttpError] {
  if @util.status_allowed(response.status, response.config) {
    Ok(response)
  } else {
    Err(status_error(response.status, response.config, response))
  }
}
