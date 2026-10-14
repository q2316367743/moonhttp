// ============================================================================
// 根包是**纯门面**：不含任何实现，只做两类事——
//   1. `pub using` 再导出各子包的公开类型（与工厂函数）；
//   2. 让使用者只 import 一个 `@moonhttp` 就拿到全部公开 API。
//
// 实现分布在三个业务子包里（分层依据与完整 DAG 见 `docs/01-architecture.md`）：
//   response/    —— 读全量的响应值（`Response`，不抛 `HttpError`）
//   http_error/  —— 纯错误契约（`HttpError` / `ErrorInfo` / `ErrorCode`，不造错误）
//   client/      —— 编排层（`Client`、拦截器、流式响应、重定向、错误构造）
//
// 关于 catch 的写法：`pub using` 能再导出类型，但**再导出不了构造器**
// （当前工具链实测，证据与备选方案见 `docs/01-architecture.md`），所以
// 错误构造器要写类型限定的形式：
//
//   catch { @moonhttp.HttpError::HttpError(info) => ... }
//
// 类型注解（`@moonhttp.HttpError`）、方法调用（`error.code()` 等）与
// `raise @moonhttp.HttpError` 签名都不受影响。凡是出现在公开签名里的类型
// 都在这里再导出一次，因此不会出现「要用这个 API 却不知道类型该从哪 import」。
// 需要精细控制的使用者（例如自己实现 `Transport`）仍可直接依赖对应子包。
// ============================================================================

///|
/// 配置与请求体相关类型：`with_data_from_form` 的入参是 `FormData`，
/// `serialize_body` 的返回值是 `SerializedBody`，流式请求体（docs/20）的载荷
/// 是 `StreamBody`——自定义传输实现按 `RequestBody::Stream` 解构时要用到它。
/// 进度回调的类型同理：`with_on_upload_progress` 的入参是 `ProgressCallback`。
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
  type StreamBody,
  type ProgressEvent,
  type ProgressCallback,
}

///|
/// 取消原语：三个入口与七个快捷方法的 `signal?` 参数类型是 `AbortSignal`，
/// 而取消之后调用方还要拿它查状态（`aborted` / `reason`），叫停则要用
/// `AbortController`。信号不是配置字段，所以直接从定义它的 `abort` 包再导出。
pub using @abort {type AbortController, type AbortSignal}

///|
pub using @headers {type Headers}

///|
/// SSE 解析器：它是独立的纯逻辑包，既能被 `Client::sse` 驱动，
/// 也能用在别的字节来源上（文件、WebSocket），是「服务端不声明
/// `text/event-stream` 时自己接」的公开逃生口。
pub using @sse {type SseEvent, type SseParser}

///|
/// 传输层抽象：自定义传输实现是公开的扩展点。
pub using @transport {trait Transport}

///|
/// 缺省传输实现（自研 HTTP/1.x 栈）。连接池自 2026-10 起是它的缺省
/// 行为（docs/21）；池参数（每 host 空闲上限、空闲保活时长）经
/// `HttpConnTransport::new(max_idle_per_host?, idle_timeout_ms?)` 调优，
/// 传给 `Client::new(transport=...)` 即可，`Client::create` 派生的
/// 实例共享同一个池。
pub using @httpconn {type HttpConnTransport}

///|
/// cookie 罐：`Client::new(cookie_jar~)` 的入参类型。
/// 传入后请求按 URL 自动携带、响应自动存取、过期自动失效，
/// 契约见 `docs/19-cookies.md`。
pub using @cookie {type CookieJar}

///|
/// 响应值与错误契约（定义在 response / http_error 包）。
pub using @response {type Response}

///|
pub using @http_error {type HttpError, type ErrorCode, type ErrorInfo}

///|
/// 编排层：客户端实例、拦截器集合、两个流式类型，以及两段拦截器的
/// 四个函数类型；`create` / `default_client` 两个工厂也随类型一起再导出。
pub using @client {
  type Client,
  type Interceptors,
  type StreamResponse,
  type SseStream,
  type RequestInterceptor,
  type RequestErrorHandler,
  type ResponseInterceptor,
  type ResponseErrorHandler,
  create,
  default_client,
}
