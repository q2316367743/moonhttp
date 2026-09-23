///|
/// 流式响应：状态行与响应头已经到手，响应体按需读取。
///
/// 与 `Response` 的差别都由「响应体还没读」这一条派生出来：
/// - 没有 `data`：响应体可能无限长，没法用 `Json` 表示；
/// - 没有 `raw`：字节还没读出来，需要时用 `read_all()` 取；
/// - 读取随时可能失败：统一抛 `HttpError`，调用方不必认识传输层错误。
///
/// 状态码与响应头这些「不读 body 就能拿到」的信息与 `Response` 保持一致，
/// 所以拿到流之后可以先按状态码与 `Content-Type` 决定怎么读。
pub(all) struct StreamResponse {
  /// HTTP 状态码
  status : Int
  /// 状态码对应的原因短语，例如 `OK`
  status_text : String
  /// 响应头（大小写不敏感）
  headers : Headers
  /// 触发这次响应的配置（**已完成合并**），与 axios 的 `response.config` 一致
  config : Config
  /// 响应体流。字段私有：读取入口都在本类型的方法上，
  /// 这样错误才能统一映射成 `HttpError` 而不是把传输层错误漏出去。
  priv body : @transport.ResponseBody
}

///|
/// 状态码是否落在 2xx。
///
/// 与 `Response::is_success` 一样，是给自定义了 `validate_status`
/// （放行了 3xx/4xx）的场景用的：默认配置下能拿到响应就说明已经通过了校验。
pub fn StreamResponse::is_success(self : StreamResponse) -> Bool {
  self.status >= 200 && self.status < 300
}

///|
/// 读取一段响应体；到 EOF 返回 `None`，此时连接已经关闭。
///
/// 返回的块大小不保证（取决于对端一次发了多少数据），需要按边界切分的
/// 协议请用 `read_until`，不要自己假设一个块就是一条消息。
pub async fn StreamResponse::read_some(
  self : StreamResponse,
  max_len? : Int,
) -> Bytes? raise HttpError {
  try {
    match max_len {
      Some(limit) => self.body.read_some(max_len=limit)
      None => self.body.read_some()
    }
  } catch {
    error => raise transport_error(error, self.config)
  }
}

///|
/// 读到分隔符 `sep` 为止，返回 `sep` 之前的内容（`sep` 被消费掉但不返回）。
///
/// 到 EOF 时把剩余内容当作最后一段返回，再读一次才返回 `None`。
/// SSE 就是靠这个语义按空行切事件的：`read_until("\n\n")` 一次拿一个事件。
pub async fn StreamResponse::read_until(
  self : StreamResponse,
  sep : String,
) -> String? raise HttpError {
  self.body.read_until(sep) catch {
    error => raise transport_error(error, self.config)
  }
}

///|
/// 读到 EOF，返回剩下的全部字节，并关闭流。
///
/// 用于「先拿流判断状态码、再一次性取内容」的场景（例如下载）。
pub async fn StreamResponse::read_all(
  self : StreamResponse,
) -> Bytes raise HttpError {
  self.body.read_all() catch {
    error => raise transport_error(error, self.config)
  }
}

///|
/// 关闭响应体流并释放连接。幂等。
///
/// 只读了半截就停止（例如 SSE 收到想结束就断开）时必须显式调用，
/// 否则连接会一直挂着。
pub fn StreamResponse::close(self : StreamResponse) -> Unit {
  self.body.close()
}
