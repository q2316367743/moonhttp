// SSE 自动重连策略：`SseReconnect` 值类型与 `Config::with_sse_reconnect`。
// 与 Config 拆在不同文件，便于各自独立演进（也满足 AGENTS.md RL-04 的 300 行上限）。
// 构建器放在这里而不是 config.mbt，是为了让「SSE 重连相关的形状」集中在一处。

///|
/// SSE 自动重连策略，挂在 `Config` 的 `sse_reconnect` 字段上。
///
/// 默认关闭：不设置它时 `SseStream` 保持原有语义——读到 EOF 返回 `None`，
/// 不自动重订阅。设置之后只影响 `Client::sse`，对 `request` / `stream`
/// 没有任何作用。
///
/// 重连间隔优先使用流里最近一次 `retry:` 的值；流里没给过才用
/// `default_delay`。与 EventSource 一致，不做指数退避。
pub(all) struct SseReconnect {
  /// 连续重连次数上限；`None` 表示不限次数（对齐 EventSource 的默认行为）。
  ///
  /// 「连续」以「有没有交付过事件」为界：每交付一个事件就清零，
  /// 所以长期运行、偶尔断线的流不会因为总次数攒到上限而被放弃。
  /// `0` 表示不重连。
  max_retries : Int32?
  /// 流里没有出现过 `retry:` 时使用的默认重连间隔（毫秒）。
  default_delay : Int32
} derive(Eq, Debug)

///|
pub extend SseReconnect with Eq::{equal, not_equal}

///|
pub extend SseReconnect with @debug.Debug::{to_repr}

///|
/// 默认策略：不限次数，间隔 3000 毫秒。
///
/// 与浏览器 EventSource 的默认口径一致；需要有限次数或自定义间隔时
/// 用 `with_max_retries` / `with_default_delay` 派生。
pub fn SseReconnect::new() -> SseReconnect {
  { max_retries: None, default_delay: 3000, }
}

///|
/// 设置连续重连次数上限。负数按 `0` 处理（等价于不重连）。
pub fn SseReconnect::with_max_retries(
  self : SseReconnect,
  max_retries : Int32,
) -> SseReconnect {
  { ..self, max_retries: Some(if max_retries < 0 { 0 } else { max_retries }), }
}

///|
/// 设置流里没有 `retry:` 时使用的默认重连间隔（毫秒）。
/// 负数按 `0` 处理；`0` 表示立即重连，注意服务端连续关闭时会形成忙循环。
pub fn SseReconnect::with_default_delay(
  self : SseReconnect,
  milliseconds : Int32,
) -> SseReconnect {
  { ..self, default_delay: if milliseconds < 0 { 0 } else { milliseconds }, }
}

///|
/// 紧凑渲染策略，与 `Config::to_string` 的格式一致。
pub fn SseReconnect::to_string(self : SseReconnect) -> String {
  let buf = StringBuilder()
  let limit = match self.max_retries {
    Some(limit) => limit.to_string()
    None => "unlimited"
  }
  ignore(push_field(buf, true, "max_retries", limit))
  ignore(
    push_field(buf, false, "default_delay", self.default_delay.to_string()),
  )
  render_braced("SseReconnect", buf.to_string(), false)
}

///|
pub impl Show for SseReconnect with fn to_string(self) {
  self.to_string()
}

///|
pub extend SseReconnect with Show::{output}

///|
/// 开启 SSE 自动重连，对应 axios 风格的配置项。
///
/// ```moonbit nocheck
/// let config = Config::new("/events").with_sse_reconnect(
///   SseReconnect::new().with_max_retries(5).with_default_delay(1000),
/// )
/// ```
///
/// 策略是**整体替换**的：请求级提供了就覆盖实例默认值，不会逐字段合并。
/// 只想用默认策略时写 `Config::new("/events").with_sse_reconnect(SseReconnect::new())`。
pub fn Config::with_sse_reconnect(
  self : Config,
  reconnect : SseReconnect,
) -> Config {
  { ..self, sse_reconnect: Some(reconnect), }
}
