// stream.mbt 拆出来的另一半：「读全量」三件套（drain / read_all_partial / read_all）。
//
// 为什么单独一个文件：AGENTS.md RL-04 对子包文件的上限是 300 行，加上下载进度
// 报告后 stream.mbt 会超限；而「读全量」正好是能整体搬走的一块——它只用
// `read_or_fail` / `close` 这些同包可见的原语，与「按块读」也确实是两组语义。
//
// 下载进度的契约（谁触发、粒度、total 从哪来）见 `docs/10-progress.md`。

///|
/// 内存体上模拟的「一次到货多少字节」，只影响进度回调的粒度。
///
/// 内存体不带 `max_len` 时其实一次就能把剩余的字节全给出去，真实连接则是
/// 对端发多少到多少。按固定大小报告，内存体的回调节奏才与真实连接一致——
/// Mock 的用例也才能确定地观察到「多块递增」。
const PROGRESS_CHUNK_SIZE : Int = 65536

///|
/// 把连接上的剩余字节读进 `buffer`，直到 EOF，逐块报告下载进度。
///
/// 单独抽出来是为了让它作为**一个整体**交给 `read_or_fail`：读全量的超时
/// 口径与逐次读取不同（整段读完受一次 `timeout` 约束，见 `read_all_partial`），
/// 分成多次读取会把这个口径改掉。
///
/// `loaded` 从 0 起算，只统计**这次读取**取到的字节；`total` 是响应体的总长度
/// （可能未知）。
async fn drain_into(
  client : @http.Client,
  buffer : @buffer.Buffer,
  total : Int?,
  on_progress : @config.ProgressCallback?,
) -> Unit {
  let mut loaded = 0
  while client.read_some() is Some(chunk) {
    buffer.write_bytes(chunk)
    loaded = loaded + chunk.length()
    match on_progress {
      Some(report) => report({ loaded, total, })
      None => ()
    }
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
///
/// `on_progress` 有值时逐块报告下载进度。它是**这次读取**的进度而不是整个
/// 响应体的：`loaded` 从 0 起算，先按块读过一段再调用本函数时不会接着累加。
/// 回调在读取过程中同步执行，占用的也是这次读取的时间预算（`timeout`）。
pub async fn ResponseBody::read_all_partial(
  self : ResponseBody,
  on_progress? : @config.ProgressCallback,
) -> (Bytes, TransportError?) noraise {
  match self.inner {
    Closed => (b"", None)
    Memory(memory) => {
      let start = memory.offset
      let end = memory.data.length()
      match on_progress {
        Some(report) => {
          // 内存体其实一次就能给完，这里按 PROGRESS_CHUNK_SIZE 模拟「分块到货」，
          // 让 Mock 观察到的回调节奏与真实连接一致（真实连接报告的是
          // 每次 read_some 的实际块大小）。
          let mut loaded = 0
          while loaded < end - start {
            let mut next = loaded + PROGRESS_CHUNK_SIZE
            if next > end - start {
              next = end - start
            }
            loaded = next
            report({ loaded, total: self.total, })
          }
        }
        None => ()
      }
      let tail = memory.data.exact_view(start~, end~).to_owned()
      memory.offset = end
      self.close()
      (tail, None)
    }
    Http(client) => {
      let buffer = @buffer.Buffer::Buffer()
      // 失败不当异常走，而是作为值返回：调用方要的是「已读到的字节 + 错误」。
      let failure : TransportError? = try {
        read_or_fail(self.timeout, () => {
          drain_into(client, buffer, self.total, on_progress)
        })
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
///
/// `on_progress` 原样转交给 `read_all_partial`。
pub async fn ResponseBody::read_all(
  self : ResponseBody,
  on_progress? : @config.ProgressCallback,
) -> Bytes raise TransportError {
  let (bytes, failure) = self.read_all_partial(on_progress?)
  match failure {
    None => bytes
    Some(error) => raise error
  }
}
