///|
/// 真实传输层：把请求交给 `moonbitlang/async/http`，真的走网络。
///
/// 这是整个模块唯一碰网络的地方。上层拿到的 `RawResponse` 已经与底层类型解耦，
/// 所以底层库升级或替换不会波及配置合并、URL 拼接等逻辑。
///
/// 当前实现每次都新建连接（用底层的 `request` 便捷函数），不做连接复用；
/// 代理与 TLS 校验开关也暂未暴露，见 README 的「暂不支持」清单。
pub struct AsyncHttpTransport {}

///|
/// 创建真实传输层。
pub fn AsyncHttpTransport::new() -> AsyncHttpTransport {
  AsyncHttpTransport::{ }
}

///|
/// 本项目的 `Method` 到底层 `RequestMethod` 的一一映射。
///
/// 两个枚举的构造子完全对应，映射写在这里而不是做成类型别名，
/// 是为了让上层完全不认识底层类型——上层的纯逻辑包不需要依赖 async。
fn to_request_method(meth : @config.Method) -> @http.RequestMethod {
  match meth {
    Get => @http.RequestMethod::Get
    Head => @http.RequestMethod::Head
    Post => @http.RequestMethod::Post
    Put => @http.RequestMethod::Put
    Delete => @http.RequestMethod::Delete
    Connect => @http.RequestMethod::Connect
    Options => @http.RequestMethod::Options
    Trace => @http.RequestMethod::Trace
    Patch => @http.RequestMethod::Patch
  }
}

///|
/// 把我们的头集合转成底层要求的 `Map[CaseInsensitiveString, String]`。
///
/// 两者都是大小写不敏感的容器，这里只做类型搬运，不改变任何语义。
fn to_http_headers(
  headers : @headers.Headers,
) -> Map[@http.CaseInsensitiveString, String] {
  let result : Map[@http.CaseInsensitiveString, String] = Map([])
  for entry in headers.entries() {
    result[@http.CaseInsensitiveString(entry.0)] = entry.1
  }
  result
}

///|
/// 把底层响应头转回我们自己的 `Headers`。
///
/// 注意 `Set-Cookie` 不在这里：底层把响应 cookie 单独放在 `Response::cookies`
/// 里，不混进 headers，所以本项目也不提供 `headers.get("Set-Cookie")`
/// （见 README 的「暂不支持」清单）。
fn from_http_headers(
  headers : Map[@http.CaseInsensitiveString, String],
) -> @headers.Headers {
  let mut result = @headers.Headers::new()
  for name, value in headers {
    result = result.set(name.to_string(), value)
  }
  result
}

///|
/// 真正发请求。超时用 `@async.with_timeout` 包裹，
/// 底层超时会抛 `TimeoutError`，在这里被映射成传输层的 `Timeout`。
///
/// 错误分类的意义在于：上层只需要认识 `TransportError` 就能决定
/// 对外报 `ErrorCode::Timeout` 还是 `ErrorCode::Network`，
/// 不必知道底层用的是哪套 HTTP 实现、抛了哪些具体错误类型。
// 实现里的方法写 `fn` 而不是 `async fn`：异步性是 trait 声明的一部分，
// 由 trait 决定，实现侧不再重复标注（与 moonbitlang/async 自身的写法一致）。
pub impl Transport for AsyncHttpTransport with fn send(self, request) {
  ignore(self)
  let body : &@io.Data = match request.body {
    Some(bytes) => bytes
    // 底层的 request 要求显式给出 body，无 body 时传空字节串。
    None => b""
  }
  try {
    // timeout 为 None 或非正数时不加限制，避免把「不限时」误当成「立即超时」。
    let (response, response_body) = match request.timeout {
      Some(milliseconds) if milliseconds > 0 =>
        @async.with_timeout(milliseconds, () => {
          @http.request(
            request.url,
            to_request_method(request.http_method),
            to_http_headers(request.headers),
            body,
          )
        })
      _ =>
        @http.request(
          request.url,
          to_request_method(request.http_method),
          to_http_headers(request.headers),
          body,
        )
    }
    {
      status: response.code,
      status_text: response.reason,
      headers: from_http_headers(response.headers),
      // binary() 取出完整响应体字节；它对内容是二进制还是文本不作判断，
      // 文本/JSON 的解析留给上层的 response_type 处理。
      body: response_body.binary(),
    }
  } catch {
    @async.TimeoutError => raise TransportError::Timeout
    // 其余错误（连接失败、DNS、TLS、协议错误等）统一归到网络层失败，
    // 并保留原始错误文本，便于排查。
    error => raise TransportError::Network(error.to_string())
  }
}

///|
pub extend AsyncHttpTransport with Transport::{send}
