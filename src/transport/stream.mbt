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
///
/// 本文件只放**读**这一半（读语义、超时、取消作用域）；构造与释放
/// （`from_bytes` / `open` / `rewind` / `close`）在 `stream_lifecycle.mbt`，
/// 读全量那三件套在 `stream_all.mbt`——都是 RL-04 的 300 行上限逼出来的拆分。
pub struct ResponseBody {
  priv mut inner : BodyInner
  /// 单次读取的等待上限（毫秒），来自 `PreparedRequest::timeout`；
  /// `None` 或 `<= 0` 表示不限时——长连的 SSE 请求就应该这样设置。
  priv timeout : Int?
  /// 这个响应体的总字节数，供下载进度给 `ProgressEvent::total` 用。
  ///
  /// 真实连接上是响应头的 `Content-Length`（chunked 响应没有，即 `None`）；
  /// 内存体是手上这份字节的长度（完整字节在手，长度总是已知）。
  /// 读取过程中不随消费变化：它描述的是**整个**响应体，不是「还剩多少」。
  priv total : Int?
  /// 这次响应体所属请求的取消句柄，来自 `PreparedRequest::cancel_token`。
  /// `None` 表示这个响应体不可取消（Mock 与自定义实现造的就是这种）。
  priv cancel_token : CancelToken?
  /// 挂在 token 上的「取消即关闭这条连接」那个登记的票号；`close()` 时注销。
  priv mut cancel_ticket : Int?
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
/// 按 `timeout` 执行一次读操作，并把底层错误收敛成传输层错误。
///
/// 超时是**单次读取**的等待上限，不是整条请求的总时限：响应头已经到手，
/// 剩下的时间只用于等数据。这既保住了「响应体下载慢也会超时」的原有行为，
/// 也让 SSE 这种「长时间没有数据是正常的」场景可以通过
/// `timeout: None` 真正长连。
///
/// `token` 有值时这次读取跑在可中断的子任务里：取消一旦发生，挂起中的读
/// 立刻断，抛 `TransportError::Cancelled`。取消作用域套在**错误收敛之外**——
/// 取消不是网络失败，不能被下面那条 catch-all 吞成 `Network`；同理它也不受
/// `timeout` 约束，取消比超时先到就报取消。
async fn[T] read_or_fail(
  timeout : Int?,
  token : @config.CancelToken?,
  read : async () -> T,
) -> T raise TransportError {
  let attempt = () => {
    match timeout {
      Some(milliseconds) if milliseconds > 0 =>
        @async.with_timeout(milliseconds, read)
      _ => read()
    }
  }
  let mapped = () => {
    attempt() catch {
      @async.TimeoutError => raise TransportError::Timeout
      // 其余错误（连接被断开、TLS、协议错误等）统一归到网络层，并保留原始错误文本。
      error => raise TransportError::Network(error.to_string())
    }
  }
  with_cancel_scope(token, mapped)
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
  // 取消发生在两次读取之间时，这里报取消而不是把已关闭的流当成 EOF——
  // 否则 `while read_some() is Some(_)` 会安静地结束，调用方以为对端正常收尾。
  match cancelled_failure(self.cancel_token) {
    Some(error) => raise error
    None => ()
  }
  // 读失败后连接状态已不可信：统一在这里关掉，调用方拿到的是
  // Timeout / Network / Cancelled 分类，而不是一个「看起来还能用」的流。
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
      match read_or_fail(self.timeout, self.cancel_token, read) {
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
/// 读到分隔符 `sep` 为止，返回 `sep` 之前的内容；`sep` 被消费掉但不返回。
///
/// 到 EOF 时把剩余内容当作最后一段返回，再读一次才返回 `None`——
/// 与 `@io.Reader::read_until` 一致。SSE 这类「按空行切事件」的协议
/// 可以直接 `read_until("\n\n")` 取一个事件，不必自己处理跨块的边界。
pub async fn ResponseBody::read_until(
  self : ResponseBody,
  sep : String,
) -> String? raise TransportError {
  // 与 read_some 同样的理由：取消之后要报取消，不能退化成「读到 EOF」。
  match cancelled_failure(self.cancel_token) {
    Some(error) => raise error
    None => ()
  }
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
      match
        read_or_fail(self.timeout, self.cancel_token, () => {
          client.read_until(sep)
        }) {
        None => {
          self.close()
          None
        }
        Some(text) => Some(text)
      }
  }
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
