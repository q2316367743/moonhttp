// ============================================================================
// 发送与自动跟随重定向：一次「跳」的完整流程——拼请求（含压缩声明与
// cookie 注入）→ 发送 → 收 Set-Cookie → 需要时跟下一跳。
//
// 拦截器**不在**这一层：每跟随一跳就调一次 `transport.send`，把拦截器挂进来
// 会让它每跳重跑一遍（认证头重复注入、重试被放大成「跳数 × 重试次数」）。
// 两段拦截器都落在 `Client::request` 与两个流式入口里，整条重定向链只跑一次。
// ============================================================================

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
/// `HttpError`，也拿不到 `ErrorCode`），错误码与文案只能由编排层决定。
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
        // 流式请求体只在首跳有效（docs/20）：`next_redirect` 没把这一跳降级成
        // GET，意味着下一跳要**原样重发请求体**——流已随首跳写完耗尽，
        // 重放只会静默发出空体。降级成 GET 的跳转（303、301/302 上的 POST）
        // 在 `next_redirect` 里就已把 data 清掉，不会走到这里。
        if next.has_stream_body() {
          let (body, _failure) = raw.body.read_all_partial()
          raise stream_replay_error(
            raw.status,
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
