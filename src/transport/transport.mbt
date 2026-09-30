///|
/// 这两个类型出现在 `PreparedRequest` / `RawResponse` 的公开签名里，
/// 因此随本包一起再导出，使用者不必为了构造一份请求再 import 两个包。
/// `AbortSignal` 同理：它由 `PreparedRequest` 携带到这一层（定义在 `abort` 包）。
pub using @config {type Method, type ProgressCallback}

///|
pub using @abort {type AbortSignal}

///|
pub using @headers {type Headers}

///|
/// 走代理需要的两样东西：连到哪儿、以及 CONNECT 请求带什么凭据。
///
/// 已经是**解析完的最小形态**：协议名与端口默认值在拼请求时就写进了 `url`，
/// 凭据也已经编码成可直接落头的字符串。这样传输层不必认识 `ProxyProtocol`
/// 这类配置枚举，也不必知道 Basic 认证怎么编码——与 `PreparedRequest`
/// 「不含任何配置语义」的口径一致。
pub(all) struct ProxyEndpoint {
  /// 代理服务器地址，形如 `http://127.0.0.1:9000`；
  /// 不带端口时由底层按协议补默认端口（http 80 / https 443）
  url : String
  /// 建立隧道用的 `Proxy-Authorization` 头值（如 `Basic ...`）；
  /// `None` 表示匿名代理
  authorization : String?
} derive(Debug)

///|
pub extend ProxyEndpoint with @debug.Debug::{to_repr}

///|
/// 交给传输层去发送的一份请求。
///
/// 到达这一步时，配置合并、`base_url` 拼接、query 序列化、头拍平都已经完成，
/// 所以它只包含「把字节发出去」真正需要的信息，不含任何配置语义。
/// 这样任何实现——真实的 HTTP、测试用的 Mock、将来可能的连接池——
/// 都只需要关心这一层，替换传输实现不会影响上层语义。
pub(all) struct PreparedRequest {
  /// 请求方法（与 Config 一样用 http_method，避开 MoonBit 的保留字 method）
  http_method : @config.Method
  /// 完整地址，已包含 `base_url` 拼接结果与序列化后的 query
  url : String
  /// 已按 common < 按方法 < 请求级 拍平的最终头集合
  headers : @headers.Headers
  /// 请求体字节；`None` 表示不带 body
  body : Bytes?
  /// 超时毫秒数；`None` 或 `<= 0` 表示不限时。
  ///
  /// 分两段生效：建连到拿到响应头这一段整体受它约束，响应体每次读取也受
  /// 它约束（见 `ResponseBody`）。所以长连的 SSE 请求应当传 `None`。
  /// 走代理时**建连包含与代理的 CONNECT 握手**，它同样落在这段时限里。
  timeout : Int?
  /// 代理服务器；`None` 表示直连。
  ///
  /// 有代理时流量全部经代理转发，http 目标也走 CONNECT 隧道（见 `docs/09-proxy.md`）。
  proxy : ProxyEndpoint?
  /// 上传进度回调；`None` 表示这次请求不报告进度。
  ///
  /// **由传输实现负责调用**：在把 `body` 写出去的过程中逐块报告。
  /// 内置的传输实现（httpconn）会按 64 KiB 分块写入并逐块回调；
  /// 自定义实现可以不调用它（测试用的 `MockTransport` 就不调用——
  /// 它不真的发送数据，所以上传进度无从报告）。
  /// 语义与粒度见 `docs/10-progress.md`。
  on_upload_progress : ProgressCallback?
  /// 这次请求的取消信号；`None` 表示不可取消。
  ///
  /// **由传输实现负责尊重它**：内置的 httpconn 在进入每一跳的发送
  /// 作用域时先查 `aborted()`（挡住「取消发生在两段 I/O 之间」），再在响应体每次
  /// 读取时登记中断手段——取消一旦发生，挂起中的连接动作会立刻被中断，
  /// 对外表现为 `TransportError::Cancelled`。
  /// 自定义实现可以不理会它（测试用的 `MockTransport` 就不理会——它不真的
  /// 做 I/O，没有「挂起」可中断；这种情况下取消仍然由上层在请求进入管线时
  /// 的预检查兜住「已取消的 signal」这一种情况）。
  /// 语义与覆盖范围见 `docs/12-cancellation.md`。
  signal : AbortSignal?
}

///|
/// 手写 Debug 而不是 `derive(Debug)`：`on_upload_progress` 是函数类型，
/// 函数没有可打印的内容。两处刻意与默认渲染不同：
/// - 回调渲染成 `<fn>` / `<none>`（与 `Config` 对函数字段的处理一致）；
/// - `body` 只给字节数，`proxy` 只给地址：前者可能是整个上传文件的内容，
///   后者的 `authorization` 是一份凭据，都不该整段进日志。
pub impl @debug.Debug for PreparedRequest with fn to_repr(self) {
  let body = match self.body {
    Some(bytes) =>
      @debug.Repr::opaque_(
        "Bytes",
        @debug.Repr::integer(bytes.length().to_string()),
      )
    None => @debug.Repr::literal("None")
  }
  let fields : Map[String, @debug.Repr] = Map([])
  fields["http_method"] = @debug.Repr::string(self.http_method.to_string())
  fields["url"] = @debug.Repr::string(self.url)
  fields["headers"] = @debug.Repr::string(self.headers.to_string())
  fields["body"] = body
  fields["timeout"] = match self.timeout {
    Some(milliseconds) => @debug.Repr::integer(milliseconds.to_string())
    None => @debug.Repr::literal("None")
  }
  fields["proxy"] = match self.proxy {
    Some(endpoint) =>
      @debug.Repr::opaque_("ProxyEndpoint", @debug.Repr::string(endpoint.url))
    None => @debug.Repr::literal("None")
  }
  fields["on_upload_progress"] = match self.on_upload_progress {
    Some(_) => @debug.Repr::literal("<fn>")
    None => @debug.Repr::literal("<none>")
  }
  // 信号与回调一样只区分「有没有」：它的取消状态会随外部调用变化，
  // 渲染进去会让同一份请求在不同时刻给出不同字符串。
  fields["signal"] = match self.signal {
    Some(_) => @debug.Repr::literal("<signal>")
    None => @debug.Repr::literal("<none>")
  }
  @debug.Repr::opaque_("PreparedRequest", @debug.Repr::record(fields))
}

///|
pub extend PreparedRequest with @debug.Debug::{to_repr}

///|
/// 传输层拿到的原始响应。
///
/// 刻意不叫 `Response`：上层对外的 `Response` 还要承担 JSON 解析、
/// 状态码校验等语义，那些不属于传输层的职责。
///
/// `body` 是**流**而不是字节：`send` 返回时只保证状态行与响应头已到手，
/// 响应体按需读取（`ResponseBody`）。底层原语只保留最弱的能力，
/// 一次性读全是上层的组合结果——这样 chunked / SSE 这类「边到边读」
/// 的协议才能表达出来。
pub(all) struct RawResponse {
  status : Int
  status_text : String
  headers : @headers.Headers
  body : ResponseBody
  /// `Set-Cookie` 的**全部值**，按响应里的出现顺序。它是多值头
  /// （RFC 9110 §5.2 明确不许合并），不能走单值的 `headers`——两个内置
  /// 传输层都在这里补全量，`headers` 里那份「只有一个值」的残留不要依赖。
  /// cookie jar（`@moonhttp.CookieJar`）自动维护用的就是这份列表。
  set_cookies : Array[String]
} derive(Debug)

///|
pub extend RawResponse with @debug.Debug::{to_repr}

///|
/// 传输层错误：把「网络世界里可能出什么事」收敛成五种情况，
/// 上层再映射成对外的 `ErrorCode`。
///
/// 有了这层收敛，上层不需要 import 任何 async 相关的包，
/// 自定义传输实现也不需要知道底层用的是哪套 HTTP 库。
pub(all) suberror TransportError {
  /// 超时（底层抛出的超时会被映射到这里）
  Timeout
  /// 网络层失败：连接失败、DNS 解析失败、TLS 握手失败等
  Network(String)
  /// 请求还没发出去就失败了：协议不支持、地址非法等
  Unsupported(String)
  /// 响应体与它声称的元数据不符：声明了 `Content-Encoding: gzip`，字节却不是
  /// 合法、完整的 gzip 流（头非法、数据损坏、被截断）。上层映射成
  /// `ERR_BAD_RESPONSE`——这不是网络故障，是响应本身解不开。
  ///
  /// 目前只有 `decode_gzip` 抛它（见 decode.mbt）。
  Malformed(String)
  /// 被取消信号叫停了；载荷是取消理由（`AbortSignal::reason()`），没给理由就是 `None`。
  ///
  /// 理由随错误一起上来，是因为信号**不在配置里**（它只从三个入口的 `signal?` 参数
  /// 进来，见 `12-cancellation.md`）——上层拿不到「这次请求用的是哪个信号」，
  /// 只能由抛错的一方（`with_abort_scope` / `aborted_failure`）随手带上。
  /// 文案仍由上层决定（默认文案在 `src/http_error.mbt` 一处），这里只表达
  /// 「这次失败是取消，不是网络故障」，上层据此报 `ERR_CANCELED` 而不是 `ERR_NETWORK`。
  Cancelled(String?)
}

///|
/// 传输层抽象：把一份准备好的请求发出去，拿回原始响应。
///
/// 用 trait 而不是直接调用异步 HTTP 库有两个目的：
/// 1. 把整个 async 运行时依赖关在实现里，上层（配置合并、URL 拼接、
///    错误映射）都能用普通同步测试覆盖；
/// 2. 使用方和测试可以注入自己的实现，不必真的发网络请求。
pub(open) trait Transport {
  async fn send(Self, PreparedRequest) -> RawResponse raise TransportError
}
