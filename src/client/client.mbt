// ============================================================================
// client 包：编排层——`Client`、拦截器链、流式响应、重定向循环，
// 以及所有「构造 `HttpError`」的动作（errors.mbt）。
//
// 依赖方向（DAG 见 docs/01-architecture.md）：`response` / `http_error` 在本包
// 下游——前者是读全量的响应值（不抛 `HttpError`），后者是纯错误契约（不造
// 错误）；「会抛错」的流式类型与「会造错」的抛错点因此都在本包，这是
// 「值 / 契约 / 行为」三层分界的落点。基础能力由 config / transport /
// httpconn / cookie / sse / util / abort 提供。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   client.mbt              —— Client 与它的构造 / 工厂、取消预检查（本文件）
//   pipeline.mbt            —— 缓冲路径管线（request）与拼 Response
//   stream_entry.mbt        —— 两个流式入口（stream / sse）
//   redirects.mbt           —— 发送与自动跟随重定向（每跳的完整流程）
//   errors.mbt              —— 错误构造：翻译 / 分档 / 校验（包私有）
//   interceptors.mbt        —— 拦截器契约与集合
//   interceptors_registry.mbt —— 注册 / 替换 / 按名移除
//   interceptors_chain.mbt  —— 三条链的驱动
//   stream_response.mbt     —— 原始字节流响应
//   sse_stream.mbt          —— SSE 事件流响应
//   shortcuts.mbt           —— 七个动词快捷方法
// ============================================================================

///|
/// 包内别名：这些裸名都来自子包（根包会用 `pub using` 对使用者再导出它们，
/// 本包内部按裸名使用）。`ErrorInfo` 只在 errors.mbt 的 `make_error` 里构造。
using @abort {type AbortSignal}

///|
using @config {type Config}

///|
using @headers {type Headers}

///|
using @http_error {type HttpError, type ErrorCode, type ErrorInfo}

///|
using @response {type Response}

// ---------------------------------------------------------------------------
// Client 与它的构造 / 工厂
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
/// 这里也是 `AbortError` 与本项目错误体系**唯一的接壤处**：abort 包是叶子，
/// 不认识任何 HTTP 错误类型，所以 `throw_if_aborted` 抛它自己的类型；
/// 这里接住并翻成统一的取消失败（`errors.mbt` 的 `abort_error`）。
/// 使用者因此只会看到一种错误类型，`is_cancelled()` 照样认得出来。
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
