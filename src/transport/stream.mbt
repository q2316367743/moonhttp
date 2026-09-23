///|
/// 响应体的可读流。
///
/// `Transport::send` 只保证「状态行与响应头已经到手，响应体按需读」，
/// 一次性读全是上层的组合结果（`Client::request` 就是 `read_all()` 之后
/// 走原来的解析流程）。这样 chunked / SSE 这类「边到边读」的协议才有落点：
/// 响应头先用于判断状态码与内容类型，数据到了再一段段取。
///
/// 内部有两种来源：真实的 HTTP 连接，以及内存字节（Mock 与测试用）。
/// 两者的读语义刻意保持一致（对齐 `@io.Reader`），Mock 才能真实代表网络侧：
/// - `read_some` 到 EOF 返回 `None`；
/// - `read_until` 消费掉分隔符，且不把分隔符放进返回值；
/// - 读到 EOF 会自动关闭底层连接，之后继续读仍然返回 `None`。
///
/// 拿到流之后必须读到 EOF 或调用 `close()`。本项目不复用连接，也没有析构器，
/// 忘记关闭就会漏掉一条 TCP 连接。
pub struct ResponseBody {
  priv mut inner : BodyInner
  /// 单次读取的等待上限（毫秒），来自 `PreparedRequest::timeout`；
  /// `None` 或 `<= 0` 表示不限时——长连的 SSE 请求就应该这样设置。
  priv timeout : Int?
}

///|
/// 响应体的实际来源。多一个 `Closed` 变体是为了让 `close()` 幂等，
/// 同时保证关闭之后再读不会碰到已经释放的连接。
priv enum BodyInner {
  Http(@http.Client)
  Memory(MemoryBody)
  Closed
}

///|
/// 内存响应体：把一份完整字节当成流来读，`offset` 记录已消费的位置。
priv struct MemoryBody {
  data : Bytes
  mut offset : Int
}

///|
/// 用内存字节构造响应体。Mock 传输层与自定义实现用它造出
/// 「不是网络来的」响应体，读语义与真实连接一致。
pub fn ResponseBody::from_bytes(data : Bytes) -> ResponseBody {
  { inner: BodyInner::Memory({ data, offset: 0, }), timeout: None, }
}

///|
/// 用一条已经收到响应头的真实连接构造响应体。
/// 只有本包内的 `AsyncHttpTransport` 会用它——连接的生命周期从这里
/// 交给响应体，读到 EOF 或 `close()` 时才会关闭。
fn ResponseBody::open(client : @http.Client, timeout : Int?) -> ResponseBody {
  { inner: BodyInner::Http(client), timeout, }
}

///|
/// 复制一份「从头开始读」的响应体。
///
/// Mock 传输层要能把同一个响应交给多次请求，就不能共用已经消费过的游标，
/// 所以它每服务一次都会 `rewind()` 一份。真实连接不可复制，返回 `None`——
/// 使用方把网络来的响应体配给 Mock 是使用错误，应当响亮失败。
fn ResponseBody::rewind(self : ResponseBody) -> ResponseBody? {
  match self.inner {
    Memory(memory) => Some(ResponseBody::from_bytes(memory.data))
    _ => None
  }
}

///|
/// 按 `timeout` 执行一次读操作，并把底层错误收敛成传输层错误。
///
/// 超时是**单次读取**的等待上限，不是整条请求的总时限：响应头已经到手，
/// 剩下的时间只用于等数据。这既保住了「响应体下载慢也会超时」的原有行为，
/// 也让 SSE 这种「长时间没有数据是正常的」场景可以通过
/// `timeout: None` 真正长连。
async fn[T] read_or_fail(
  timeout : Int?,
  read : async () -> T,
) -> T raise TransportError {
  let attempt = () => {
    match timeout {
      Some(milliseconds) if milliseconds > 0 =>
        @async.with_timeout(milliseconds, read)
      _ => read()
    }
  }
  attempt() catch {
    @async.TimeoutError => raise TransportError::Timeout
    // 其余错误（连接被断开、TLS、协议错误等）统一归到网络层，并保留原始错误文本。
    error => raise TransportError::Network(error.to_string())
  }
}

///|
/// 读取一段响应体；到 EOF 返回 `None`，此时连接已经关闭。
///
/// `max_len` 限制单次返回的字节数，缺省时能取多少取多少——
/// 与 `@io.Reader::read_some` 一样，返回的块可能小于 `max_len`，
/// 需要按长度区分的协议请自己缓冲。
pub async fn ResponseBody::read_some(
  self : ResponseBody,
  max_len? : Int,
) -> Bytes? raise TransportError {
  // 读失败后连接状态已不可信：统一在这里关掉，调用方拿到的是
  // Timeout / Network 分类，而不是一个「看起来还能用」的流。
  errdefer self.close()
  match self.inner {
    Closed => None
    Memory(memory) => {
      let remaining = memory.data.length() - memory.offset
      if remaining <= 0 {
        self.close()
        None
      } else {
        let length = match max_len {
          Some(limit) if limit < remaining => limit
          _ => remaining
        }
        let chunk = memory.data
          .exact_view(start=memory.offset, end=memory.offset + length)
          .to_owned()
        memory.offset = memory.offset + length
        Some(chunk)
      }
    }
    Http(client) => {
      let read = match max_len {
        Some(limit) => () => client.read_some(max_len=limit)
        None => () => client.read_some()
      }
      match read_or_fail(self.timeout, read) {
        None => {
          self.close()
          None
        }
        Some(chunk) => Some(chunk)
      }
    }
  }
}

///|
/// 把连接上的剩余字节读进 `buffer`，直到 EOF。
///
/// 单独抽出来是为了让它作为**一个整体**交给 `read_or_fail`：读全量的超时
/// 口径与逐次读取不同（整段读完受一次 `timeout` 约束，见 `read_all_partial`），
/// 分成多次读取会把这个口径改掉。
async fn drain_into(client : @http.Client, buffer : @buffer.Buffer) -> Unit {
  while client.read_some() is Some(chunk) {
    buffer.write_bytes(chunk)
  }
}

///|
/// 读到 EOF，返回剩下的全部字节；**失败时不抛错**，把已读到的部分与错误一起返回。
///
/// 为什么要它：网络在读到一半时断掉（超时、连接被重置）是常态，此时已经到手的
/// 字节往往正是现场——服务端错误响应的正文、JSON 的开头、下载进度。上层要把它们
/// 挂到错误上（`HttpError::response`），所以不能像 `read_all` 那样在中途失败时
/// 把字节丢掉。
///
/// 返回 `(全部字节, None)` 表示正常读完，`(已读到的部分, Some(错误))` 表示中途失败。
/// 两种情况流都已关闭，与 `read_all` 一致。超时口径也与 `read_all` 一致：
/// 整段读取受一次 `timeout` 约束，而不是每次分块各算一次。
pub async fn ResponseBody::read_all_partial(
  self : ResponseBody,
) -> (Bytes, TransportError?) noraise {
  match self.inner {
    Closed => (b"", None)
    Memory(memory) => {
      let tail = memory.data
        .exact_view(start=memory.offset, end=memory.data.length())
        .to_owned()
      memory.offset = memory.data.length()
      self.close()
      (tail, None)
    }
    Http(client) => {
      let buffer = @buffer.Buffer::Buffer()
      // 失败不当异常走，而是作为值返回：调用方要的是「已读到的字节 + 错误」。
      let failure : TransportError? = try {
        read_or_fail(self.timeout, () => drain_into(client, buffer))
        None
      } catch {
        error => Some(error)
      }
      // 读完与失败都一样：这条连接没有别的用处，释放掉（`read_some` 的
      // errdefer 已经关过一次，`close` 幂等）。
      self.close()
      (buffer.to_bytes(), failure)
    }
  }
}

///|
/// 读到 EOF，返回剩下的全部字节，并关闭流。
///
/// 这是「非流式」用法的入口：`Client::request` 就是先读完再走原有的 JSON 解析
/// 与状态码校验。中途失败时抛 `TransportError`——已经读到的部分在这一层丢掉，
/// 需要它请用 `read_all_partial`（本函数就是它的「失败即抛」包装）。
pub async fn ResponseBody::read_all(
  self : ResponseBody,
) -> Bytes raise TransportError {
  let (bytes, failure) = self.read_all_partial()
  match failure {
    None => bytes
    Some(error) => raise error
  }
}

///|
/// 读到分隔符 `sep` 为止，返回 `sep` 之前的内容；`sep` 被消费掉但不返回。
///
/// 到 EOF 时把剩余内容当作最后一段返回，再读一次才返回 `None`——
/// 与 `@io.Reader::read_until` 一致。SSE 这类「按空行切事件」的协议
/// 可以直接 `read_until("\n\n")` 取一个事件，不必自己处理跨块的边界。
pub async fn ResponseBody::read_until(
  self : ResponseBody,
  sep : String,
) -> String? raise TransportError {
  errdefer self.close()
  match self.inner {
    Closed => None
    Memory(memory) => {
      let remaining = memory.data.length() - memory.offset
      if remaining <= 0 {
        self.close()
        None
      } else {
        let haystack = memory.data.exact_view(start=memory.offset)
        let sep_bytes = @utf8.encode(sep)
        match haystack.find(sep_bytes.exact_view()) {
          Some(index) => {
            let segment = haystack.exact_view(end=index).to_owned()
            memory.offset = memory.offset + index + sep_bytes.length()
            Some(@utf8.decode_lossy(segment))
          }
          None => {
            // 找不到分隔符：剩下的就是最后一段，交出去之后流即结束。
            let segment = haystack.to_owned()
            memory.offset = memory.data.length()
            self.close()
            Some(@utf8.decode_lossy(segment))
          }
        }
      }
    }
    Http(client) =>
      match read_or_fail(self.timeout, () => client.read_until(sep)) {
        None => {
          self.close()
          None
        }
        Some(text) => Some(text)
      }
  }
}

///|
/// 关闭流并释放底层连接。幂等：重复调用只生效一次。
///
/// 只读了半截就停止（例如 SSE 收到想结束就断开）时必须显式调用它，
/// 否则连接会一直挂着。
pub fn ResponseBody::close(self : ResponseBody) -> Unit {
  match self.inner {
    Http(client) => client.close()
    _ => ()
  }
  self.inner = BodyInner::Closed
}

///|
/// 手写 Debug 而不是 derive：底层 `@http.Client` 没有 Debug。
/// 真实连接打印成占位符，内存体给出还没读完的字节数，
/// `RawResponse` 因此可以继续 derive(Debug)。
pub impl @debug.Debug for ResponseBody with fn to_repr(self) {
  match self.inner {
    Http(_) =>
      @debug.Repr::opaque_(
        "ResponseBody",
        @debug.Repr::literal("<http stream>"),
      )
    Memory(memory) =>
      @debug.Repr::opaque_(
        "ResponseBody",
        @debug.Repr::integer((memory.data.length() - memory.offset).to_string()),
      )
    Closed => @debug.Repr::literal("ResponseBody::closed")
  }
}

///|
pub extend ResponseBody with @debug.Debug::{to_repr}
