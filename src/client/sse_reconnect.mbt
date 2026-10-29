// SSE 自动重连：`SseStream::next_event` 用到的运行时状态与重连循环。
//
// 为什么循环放在 client 包而不是 sse 包：重连要重新走 HTTP 管线
// （合并配置、请求拦截器、重定向、状态码校验），还要用取消信号等待；
// sse 包保持纯逻辑，只暴露 last_id / retry 的持久状态。

///|
/// 重连所需的运行时状态。
priv struct SseReconnectState {
  /// 用来重新走完整管线（合并默认值、请求拦截器、重定向、cookie、状态码校验）。
  client : Client
  /// 调用方传进来的**原始**配置（未合并、未经过拦截器）。
  /// 每次重连都从它出发，让请求拦截器 / 重定向 / cookie 重新生效。
  config : Config
  /// 与首次请求共享的取消信号。
  signal : AbortSignal?
  /// 建流时确定的策略。
  policy : SseReconnect
  /// 连续重连次数；交付事件后清零。
  mut attempts : Int32
}

///|
/// 手写 Debug：Client 与 AbortSignal 都不该整段渲染，只给出连续失败次数。
impl @debug.Debug for SseReconnectState with fn to_repr(self) {
  @debug.Repr::opaque_(
    "SseReconnectState",
    @debug.Repr::integer(self.attempts.to_string()),
  )
}

///|
fn SseReconnectState::new(
  client : Client,
  config : Config,
  signal : AbortSignal?,
  policy : SseReconnect,
) -> SseReconnectState {
  { client, config, signal, policy, attempts: 0, }
}

///|
/// 这个失败值不值得重连。
///
/// 先看响应状态码：4xx 是「请求本身有问题」，重试只会得到同样结果；
/// 5xx 通常是暂时性故障，可以按 retry 等待后重试。没有响应（连不上、
/// 建连超时）或 2xx 上的读失败（网络断、单次读取超时）再看错误码。
/// 取消永远不重试——那是调用方主动叫停，不是连接故障。
fn retryable_error(error : HttpError) -> Bool {
  if error.is_cancelled() {
    return false
  }
  match error.response() {
    Some(response) => {
      if response.status >= 500 && response.status < 600 {
        return true
      }
      if response.status < 200 || response.status >= 300 {
        return false
      }
    }
    None => ()
  }
  match error.code() {
    ErrorCode::Network | ErrorCode::Timeout => true
    _ => false
  }
}

///|
/// 把重连请求的配置准备好：在原始配置上补 `Last-Event-ID`。
///
/// 空字符串 id 表示「服务端用 `id:` 空值清掉了」，按规范不再发这个头；
/// 解析器还没有 id 时也保留调用方自己设置的 `Last-Event-ID`。
fn SseReconnectState::next_config(
  self : SseReconnectState,
  parser : @sse.SseParser,
) -> Config {
  match parser.last_event_id() {
    Some(id) =>
      if id.is_empty() {
        self.config
      } else {
        self.config.with_header("Last-Event-ID", id)
      }
    None => self.config
  }
}

///|
/// 按策略重连，直到拿到一条可读的连接或决定放弃。
///
/// 返回 `true`：`self.body` 已经换成新连接，调用方继续读。
/// 返回 `false`：`closed` 了，或干净 EOF 下次数用尽——调用方应返回 `None`。
/// 抛错：最后一次失败是错误且次数用尽，或遇到不可重试的错误。
///
/// `last_error` 是触发这次重连的失败：`None` 表示干净 EOF。
async fn SseStream::reconnect_loop(
  self : SseStream,
  state : SseReconnectState,
  last_error : HttpError?,
) -> Bool raise HttpError {
  let mut last_error = last_error
  while true {
    if self.closed {
      return false
    }
    match state.policy.max_retries {
      Some(limit) =>
        if state.attempts >= limit {
          match last_error {
            Some(error) => raise error
            None => return false
          }
        }
      None => ()
    }
    let delay = match self.parser.retry_interval() {
      Some(milliseconds) => milliseconds
      None => state.policy.default_delay
    }
    // 等待期间取消要立刻生效；`close()` 不打断等待（见 docs/06-sse.md）。
    @transport.sleep_with_abort(state.signal, delay) catch {
      error => raise self.read_error(error)
    }
    if self.closed {
      return false
    }
    state.attempts = state.attempts + 1
    let config = state.next_config(self.parser)
    let opened = open_sse(state.client, config, state.signal) catch {
      error => {
        if !retryable_error(error) {
          raise error
        }
        last_error = Some(error)
        continue
      }
    }
    let (raw, _merged) = opened
    if self.closed {
      // 等待 / 建连期间调用方关掉了流：新连接也不能留。
      raw.body.close()
      return false
    }
    // 同一个解析器接新流：id / retry 保留，BOM 判定与上一连接残留清掉。
    self.parser.begin_stream()
    self.body = raw.body
    return true
  } nobreak {
    false
  }
  // `while true` 的兜底值；正常路径都走 return / raise，不会到这里。
}
