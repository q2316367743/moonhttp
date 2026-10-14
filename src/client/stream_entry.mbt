// ============================================================================
// 两个流式入口：`Client::stream`（原始字节流）与 `Client::sse`（事件流）。
//
// 它们与 `request` 共用前半段（合并配置 → 取消预检查 → 请求拦截器 → 发送 →
// 重定向），差别是**不读响应体**，也不跑响应侧链：手里是还没读的字节流，
// 「救回一份 Response」没有落点（见 docs/11-interceptors.md）。
// ============================================================================

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
/// 免得把二进制数据喂进事件解析器（见 `sse_stream.mbt` 里 `SseStream` 的说明）。
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
