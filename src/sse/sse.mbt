// SSE（Server-Sent Events）事件解析。
//
// 为什么不能用 `read_until("\n\n")` 切事件：规范允许行尾是 CRLF / LF / CR 三种，
// CRLF 流上事件边界的字节是 `0D 0A 0D 0A`，里面**没有**连续两个 `0A`，
// 按 `"\n\n"` 找分隔符会永远匹配不到、一直累积到连接关闭。
// 所以这里按字节扫描，自己识别三种行尾（实现见 sse_parse.mbt）。
//
// 本文件是纯逻辑：吃字节、吐事件，不碰网络、不碰 async，
// 因此规范里的每条规则都能用同步测试钉死。

///|
/// 解析里要用到的字节。写成 `Int` 再与 `Byte::to_int()` 比较，
/// 免得字节字面量散落各处。
const LF : Int = 10

///|
const CR : Int = 13

///|
const SPACE : Int = 32

///|
const COLON : Int = 58

///|
/// `retry:` 能接受的最大值。
///
/// 规范允许实现丢弃超出范围的重连间隔。取 `(2^31 - 1) / 10`：
/// 再乘 10 就会越过 32 位有符号上限，所以更大的值直接忽略而不是溢出。
/// 实际的重连间隔是秒级到分钟级，这个上限绰绰有余。
const MAX_RETRY : Int = 214_748_363

///|
/// 一个 SSE 事件，对应规范里的 `MessageEvent`。
pub(all) struct SseEvent {
  /// 事件类型，来自 `event:` 字段；流里没给过就是规范默认的 `"message"`
  event : String
  /// 事件数据，来自 `data:` 字段；同一事件里多条 `data:` 行用 `\n` 连接
  data : String
  /// 最近一次 `id:` 的值；`None` 表示流里还没出现过（见下面的「持久状态」）
  id : String?
  /// 最近一次 `retry:` 的值（毫秒）；`None` 表示流里还没出现过
  retry : Int?
} derive(Eq, Debug)

///|
pub extend SseEvent with Eq::{equal, not_equal}

///|
pub extend SseEvent with @debug.Debug::{to_repr}

///|
/// 增量式 SSE 解析器：把任意切分的字节块喂进来，取出完整事件。
///
/// 「任意切分」是重点：一次 `push` 可能包含 0 个、1 个或多个事件，
/// 一个事件也可能横跨多次 `push`——行尾、字段、甚至一个 UTF-8 字符
/// 都可能被切在中间。调用方不需要关心这些边界。
///
/// **`id` 与 `retry` 是跨事件持久的解析器状态**，对齐规范里 EventSource
/// 的内部状态：一旦出现过，就跟着后面每个事件一起交出去。断线重连要用
/// 这两个值，所以本项目不自动重连，但把它们交给调用方（见 docs/06-sse.md）。
///
/// **EOF 时未完成的事件块丢弃**（规范行为）：没有等到空行的事件不算数，
/// 解析器也不会在流结束时补发。
pub struct SseParser {
  /// 还没被消费的字节：最多是「一行的一部分」加可能的半个 CRLF
  priv mut pending : Bytes
  /// 已解析完、还没被取走的事件
  priv mut ready : Array[SseEvent]
  /// 已取走的事件数；游标走到底就清空队列（与 MockTransport 的写法一致）
  priv mut cursor : Int
  /// 当前事件累积的 `data:` 值，每个元素是一行的值，分发时用 `\n` 连接
  priv mut data : Array[Bytes]
  /// 当前事件累积的 `event:` 值；空串表示没给过
  priv mut event : String
  /// 流开头的 BOM 是否已经处理过
  priv mut head_done : Bool
  /// last event ID，跨事件持久
  priv mut last_id : String?
  /// 重连间隔（毫秒），跨事件持久
  priv mut retry : Int?
}

///|
/// 创建解析器：干净状态，没有任何事件、也没有 ID / 重连间隔。
pub fn SseParser::new() -> SseParser {
  {
    pending: b"",
    ready: [],
    cursor: 0,
    data: [],
    event: "",
    head_done: false,
    last_id: None,
    retry: None,
  }
}

///|
/// 手写 Debug 而不是 derive：内部的缓冲是读取过程的中间状态，
/// 打印出来没有意义。只给出「攒好但还没被取走的事件数」，
/// 排查「事件到底有没有解析出来」时够用。
pub impl @debug.Debug for SseParser with fn to_repr(self) {
  @debug.Repr::opaque_(
    "SseParser",
    @debug.Repr::integer((self.ready.length() - self.cursor).to_string()),
  )
}

///|
pub extend SseParser with @debug.Debug::{to_repr}

///|
/// 喂入一块字节；完整的事件会进内部队列，用 `next()` 取。
///
/// 返回时 `pending` 已经缩到「最多一行的一部分」，所以长连场景下
/// 内存不会随运行时间增长——除非对端一直不发换行。
pub fn SseParser::push(self : SseParser, chunk : Bytes) -> Unit {
  // 只有这里做字节拼接：把上一块剩下的半行与新数据接起来。
  self.pending = if self.pending.is_empty() {
    chunk
  } else {
    self.pending + chunk
  }
  self.skip_bom()
  let consumed = self.consume_lines()
  if consumed > 0 {
    self.pending = self.pending.exact_view(start=consumed).to_owned()
  }
}

///|
/// 取一个已经解析完的事件；没有就返回 `None`。
///
/// `None` 不代表流结束——也可能只是数据还没到齐，需要继续 `push`。
/// 「流是否结束」由读取侧判定（见根包的 `SseStream::next_event`）。
pub fn SseParser::next(self : SseParser) -> SseEvent? {
  if self.cursor >= self.ready.length() {
    // 取完了就清空：否则队列会随着长连一直涨。
    self.ready = []
    self.cursor = 0
    None
  } else {
    let event = self.ready[self.cursor]
    self.cursor = self.cursor + 1
    Some(event)
  }
}

///|
/// 告诉解析器「流到此结束」，读到 EOF 时调用一次。
///
/// 需要它只有一个原因：末尾那个**卡住的 CR**。`push` 遇到缓冲区最后一个字节是
/// CR 时会先不消费，因为它可能是 CRLF 的前半；流结束时不会再有 LF 了，
/// 这个 CR 就是行尾。不调用它，`data: x\r\r` 这类以裸 CR 收尾的流会少一个事件。
///
/// 未以换行收尾的半行**不会**被补发：规范要求流结束时丢弃不完整的事件。
/// 重复调用是安全的。
pub fn SseParser::finish(self : SseParser) -> Unit {
  let length = self.pending.length()
  if length > 0 && self.pending[length - 1].to_int() == CR {
    // 剩下的是一个裸 CR：它就是这一行（空行）的行尾。
    self.handle_line(0, length - 1)
  }
  // 规范：流结束时还没完成的事件丢弃。
  self.pending = b""
  self.data = []
  self.event = ""
}

///|
/// 分发当前累积的事件。
///
/// 规范里的三条规则集中在这里：
/// - `data` 缓冲为空则**不发事件**（只有 `id:` / `retry:` 或注释的块属于这种）；
///   注意 `data:` 写了空值不算「空」，那是一个 data 为空串的事件；
/// - 多条 `data:` 行用 `\n` 连接（等价于「逐行追加值并补一个 `\n`，
///   分发前去掉最后一个 `\n`」）；
/// - 事件类型为空时取默认值 `message`。
fn SseParser::dispatch(self : SseParser) -> Unit {
  // 事件类型缓冲每次分发后都要清空，**无论这次发不发事件**。
  let event_type = self.event
  self.event = ""
  let lines = self.data
  self.data = []
  if lines.length() == 0 {
    return
  }
  self.ready.push({
    event: if event_type.is_empty() {
      "message"
    } else {
      event_type
    },
    data: @utf8.decode_lossy(join_lines(lines)),
    id: self.last_id,
    retry: self.retry,
  })
}
