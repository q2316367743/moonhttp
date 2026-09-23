///|
/// 真实传输层：把请求交给 `moonbitlang/async/http`，真的走网络。
///
/// 这是整个模块唯一碰网络的地方。上层拿到的 `RawResponse` 已经与底层类型解耦，
/// 所以底层库升级或替换不会波及配置合并、URL 拼接等逻辑。
///
/// 当前实现每次都新建连接（用底层的 `@http.Client` 手动走
/// 「connect → request → write → end_request」四步），不做连接复用；
/// 代理与 TLS 校验开关也暂未暴露，见 README 的「暂不支持」清单。
/// 手动四步而非 `@http.request` 便捷函数，是为了不在传输层就把响应体读光。
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
/// 把完整地址切成「连接用的根地址」和「请求路径」两段。
///
/// 底层 `@http.Client::Client(uri)` 要求 uri 的 path 恰好是 `/`，
/// 路径要留给 `Client::request(meth, path)`，所以这里得自己切一刀；
/// 也正因为这个限制，不能用只覆盖 GET 的 `@http.get_stream`。
/// 切法镜像底层的 `resolve_url`：先按 `://` 分出协议，再取之后第一个 `/`。
///
/// 相对地址与 http/https 之外的协议都抛 `Unsupported`：
/// 它们的共同点是「请求还没发出去就失败了」，正是这个分类的定义。
fn split_url(url : String) -> (String, String) raise TransportError {
  let scheme_end = match url.find("://") {
    Some(index) => index
    None =>
      raise TransportError::Unsupported("地址不是绝对地址：" + url)
  }
  let scheme = url[:scheme_end].to_owned()
  guard scheme is ("http" | "https") else {
    raise TransportError::Unsupported("只支持 http/https 协议：" + scheme)
  }
  let rest = url[scheme_end + 3:]
  // 切不开路径时（例如 `https://host`）按 HTTP 约定补成 `/`；
  // 切到的 path 一定以 `/` 开头，正好满足 `Client::request` 对路径的要求。
  let (host, path) = match rest.find("/") {
    Some(index) => (rest[:index].to_owned(), rest[index:].to_owned())
    None => (rest.to_owned(), "/")
  }
  (scheme + "://" + host, path)
}

///|
/// 建连、发出请求头与请求体、等回响应头，然后把「还开着的连接」与响应头
/// 一起交出去。
///
/// 这一段（含等响应头）整体受 `timeout` 约束；响应体还没开始读，
/// 读取阶段的超时由 `ResponseBody` 按**单次读取**来管，见 `stream.mbt`。
/// 用 `@http.Client` 而不是 `@http.request` 的便捷函数，正是为了不在
/// 这里就把响应体读光——`end_request()` 返回时响应体还在连接上。
async fn send_head(
  request : PreparedRequest,
) -> (@http.Client, @http.Response) raise TransportError {
  let (root, path) = split_url(request.url)
  let attempt = () => {
    // 头一次性交给 connect（与便捷函数 @http.request 的用法一致：
    // 它同样是把 headers 交给 connect，body 单独 write）。
    let client = @http.Client::Client(
      root,
      headers=to_http_headers(request.headers),
    )
    // 失败路径必须关连接，否则会漏下一条没人管的半开连接。
    errdefer client.close()
    client.request(to_request_method(request.http_method), path)
    match request.body {
      Some(bytes) => {
        let data : &@io.Data = bytes
        client.write(data)
      }
      // 无 body 时什么都不写：底层据此发 Content-Length: 0 或 chunked。
      None => ()
    }
    (client, client.end_request())
  }
  try {
    // timeout 为 None 或非正数时不加限制，避免把「不限时」误当成「立即超时」。
    match request.timeout {
      Some(milliseconds) if milliseconds > 0 =>
        @async.with_timeout(milliseconds, attempt)
      _ => attempt()
    }
  } catch {
    @async.TimeoutError => raise TransportError::Timeout
    // 其余错误（连接失败、DNS、TLS、协议错误等）统一归到网络层失败，
    // 并保留原始错误文本，便于排查。
    error => raise TransportError::Network(error.to_string())
  }
}

///|
/// 真正发请求：拿回响应头与一条可读的响应体流。
///
/// 错误分类的意义在于：上层只需要认识 `TransportError` 就能决定
/// 对外报 `ErrorCode::Timeout` 还是 `ErrorCode::Network`，
/// 不必知道底层用的是哪套 HTTP 实现、抛了哪些具体错误类型。
// 实现里的方法写 `fn` 而不是 `async fn`：异步性是 trait 声明的一部分，
// 由 trait 决定，实现侧不再重复标注（与 moonbitlang/async 自身的写法一致）。
pub impl Transport for AsyncHttpTransport with fn send(self, request) {
  ignore(self)
  let (client, response) = send_head(request)
  {
    status: response.code,
    status_text: response.reason,
    headers: from_http_headers(response.headers),
    // 响应体还没读：连接的所有权转移给这个流，读到 EOF 或 close() 时关闭。
    // 不在这里读全，是为了让 chunked / SSE 这类协议能边到边读。
    body: ResponseBody::open(client, request.timeout),
  }
}

///|
pub extend AsyncHttpTransport with Transport::{send}
