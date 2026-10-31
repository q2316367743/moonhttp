// ============================================================================
// 缓冲路径的管线：`Client::request`（唯一跑完整两段拦截器的入口）、
// 派发一次请求（发送、读全量）、响应体解压与拼 `Response`。
//
// 状态码校验不在这里：它以 `Result` 的形式留在 `request` 手里
// （errors.mbt 的 `validate_response`），这样「请求阶段的失败」与「状态码失败」
// 才能分流到两条错误链（见 docs/11-interceptors.md）。
// ============================================================================

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
    // 3. 请求拦截器。被拦下时这次请求不发出，抛出的错误由外层 `try` 收进
    //    `stage`——和 4~7 的失败一样交给请求侧错误处理器。
    let config = self.interceptors.run_request(merged)
    // 4~7. 发送、跟重定向、读全量、拼响应（状态码校验不在这里）
    Ok(self.dispatch_request(config, signal))
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
  // 解压失败先抛出来，由下面的 `catch` 定夺报哪个错：状态码同样没通过校验时，
  // 状态码那个原因更准确（404 的错误页解不开，说「404」比说「解压失败」有用）。
  let (decoded, headers) = decode_response_body(
    raw.status,
    raw.status_text,
    raw.headers,
    body,
    merged,
  ) catch {
    error =>
      if @util.status_allowed(raw.status, merged) {
        raise error
      } else {
        // 状态码本身也没通过校验：以状态码为准，响应体与响应头都保持原样
        // ——字节确实还是压缩字节，`Content-Encoding` 也照原样留着（头与体一致）。
        (body, raw.headers)
      }
  }
  // 校验状态码**不在这里**：交给 `Client::request`——那里才知道这次失败该走
  // 请求侧还是响应侧的错误处理器（字符集解码同样不在这里：响应体以原始字节
  // 交出去，读法由调用方选）
  build_response(raw.status, raw.status_text, headers, decoded, merged)
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
/// 解压失败就抛 `HttpError`，错误里挂着**原始压缩字节与原始响应头**
/// ——解不开的就是这份字节，头照原样留着才看得出它声称自己是 gzip。
/// 报哪个错由调用方在 `catch` 里定夺：状态码同样没通过校验时，状态码那个原因
/// 更准确（404 的错误页解不开，说「404」比说「解压失败」有用）。
async fn decode_response_body(
  status : Int32,
  status_text : String,
  headers : Headers,
  body : Bytes,
  config : Config,
) -> (Bytes, Headers) raise HttpError {
  let needed = config.decompress.unwrap_or(true) &&
    @transport.declares_gzip(headers) &&
    body.length() > 0
  if !needed {
    return (body, headers)
  }
  let decoded = @transport.decode_gzip(body) catch {
    error =>
      raise transport_error(
        error,
        config,
        Some(build_response(status, status_text, headers, body, config)),
      )
  }
  (decoded, headers.remove("Content-Encoding").remove("Content-Length"))
}

///|
/// 把响应拼成对外的 `Response`：只放**原始字节**进去，解码不在这里
/// ——读法由调用方经 `Response::text` / `bytes` / `json` 选。
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
/// 没有 `RawResponse`。`raw` 是 `Response` 的私有字段，跨包写不出记录
/// 字面量，所以这层薄封装转调 `response` 包公开的 `Response::new`。
fn build_response(
  status : Int32,
  status_text : String,
  headers : Headers,
  body : Bytes,
  config : Config,
) -> Response {
  @response.Response::new(status, status_text, headers, body, config)
}
