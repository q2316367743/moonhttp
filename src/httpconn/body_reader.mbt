// 响应体的分帧读取：把「连接上的字节」按 `BodyFraming` 切成「响应体的字节」。
//
// 它实现 `@io.Reader`，所以可以：交给 `ResponseBody::open_wire` 当流，
// 也可以被 `@gzip.Decoder` 再包一层（流式 gzip 解压，gzip 语义由本包自持，
// 见 docs/15 / docs/17 口径 4）。分帧判定的纯逻辑在 httpproto，这里只做
// I/O 驱动——「怎么判」可以同步测试，「怎么读」跟着连接走。

///|
/// 当前分帧的读取状态。`Length` 的载荷是**还剩多少字节**；
/// `Done` 单列是为了让「读满定长」「chunked 收尾」与 Empty 一样
/// 从此稳定返回 EOF。
priv enum BodyMode {
  /// 无体（HEAD / 1xx / 204 / 304）：永远 EOF
  Empty
  /// 定长：读满即 EOF
  Length(Int)
  /// chunked：状态机在 httpproto，这里喂字节、收数据段
  Chunked(@httpproto.ChunkDecoder)
  /// 读到连接关闭为止
  UntilClose
  /// 已经读完（定长读满 / chunked 正常收尾）
  Done
}

///|
/// 分帧响应体。持有连接（所有权在 `send` 里一次性移交：
/// 连接的关闭由 `ResponseBody` 的 close 回调驱动，见 transport.mbt）。
priv struct BodyReader {
  conn : Connection
  /// 自己的输出缓冲：默认 read / read_some / read_until 先看它。
  /// 刻意**不**与连接共用 `conn.buf`——读响应头的「多读」会把原始线字节
  /// （甚至 chunked 帧头）留进连接缓冲，而默认方法「缓冲有字节就直接交出、
  /// 不再过 `_direct_read`」，从这里交出就会把帧原样漏进响应体。
  /// 本缓冲里只会出现 `_direct_read` 产出的**已解码**字节。
  buf : @io.ReaderBuffer
  mut mode : BodyMode
  /// chunked 模式的线上字节暂存：feed 之前先从连接拉一拍
  scratch : FixedArray[Byte]
  /// chunked 数据段超出单次读取容量的余量（FIFO）；`pending_off` 是
  /// 队首段的已消费位置。不设它，一次拉取解出超过 `max_len` 的数据
  /// 就会丢字节。
  mut pending : Array[Bytes]
  mut pending_off : Int
}

///|
/// 线上字节的一次拉取粒度。chunked 的数据段切分是逐字节的，这个缓冲
/// 只影响「每次从内核拿多少」，不影响正确性。
const BODY_PULL_SIZE : Int = 16384

///|
fn BodyReader::open(
  conn : Connection,
  framing : @httpproto.BodyFraming,
) -> BodyReader {
  let mode = match framing {
    @httpproto.BodyFraming::Empty => Empty
    @httpproto.BodyFraming::Length(total) => Length(total)
    @httpproto.BodyFraming::Chunked => Chunked(@httpproto.ChunkDecoder::new())
    @httpproto.BodyFraming::UntilClose => UntilClose
  }
  {
    conn,
    buf: @io.ReaderBuffer::new(),
    mode,
    scratch: FixedArray::make(BODY_PULL_SIZE, b'\x00'),
    pending: [],
    pending_off: 0,
  }
}

///|
/// 输出侧用自己的缓冲（见结构体字段注释）：这里交出的字节永远已经过
/// 分帧解码；连接自己的缓冲只是线上字节的中转，经 `conn.read` 进 `_direct_read`。
impl @io.Reader for BodyReader with fn _get_internal_buffer(self : BodyReader) -> @io.ReaderBuffer {
  self.buf
}

///|
/// 按分帧模式读出**解码后**（去 chunked 帧）的字节；0 = 响应体结束。
///
/// 两个口径：
/// - 定长不足（连接提前关闭）：按 EOF 交出已到的部分——截断的正文留给
///   上层按内容判断，不在这里改写语义；
/// - chunked 截断：`ChunkDecoder::finish` 会显式报 `Malformed`
///   ——半截的 chunked 无法自洽，宽容等于交出坏数据。
impl @io.Reader for BodyReader with fn _direct_read(
  self : BodyReader,
  dst : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  // 余量优先：上次解出没装下的数据段照常交出（哪怕分帧已收尾）
  let mut filled = self.drain_pending(dst, offset~, max_len~)
  if filled > 0 {
    return filled
  }
  match self.mode {
    Empty => 0
    Done => 0
    UntilClose => self.conn.read(dst, offset~, max_len~)
    Length(remaining) => {
      let take = if max_len < remaining { max_len } else { remaining }
      let n = self.conn.read(dst, offset~, max_len=take)
      if n == 0 {
        self.mode = Done
        return 0
      }
      if n >= remaining {
        self.mode = Done
      } else {
        self.mode = Length(remaining - n)
      }
      n
    }
    Chunked(decoder) => {
      while filled < max_len {
        let got = self.conn.read(self.scratch, offset=0, max_len=BODY_PULL_SIZE)
        if got == 0 {
          // 连接关闭：正常收尾则 Done，否则「被截断」显式失败
          decoder.finish()
          self.mode = Done
          return filled
        }
        let pieces = decoder.feed(Bytes::from_array(self.scratch[0:got]))
        for piece in pieces {
          filled += self.stash(dst, offset~, max_len~, piece, filled)
        }
        if decoder.is_done() {
          self.mode = Done
          // 终止 chunk 之后解出的尾段可能还压在 pending 里
          return filled +
            self.drain_pending(
              dst,
              offset=offset + filled,
              max_len=max_len - filled,
            )
        }
        // 一有解码产出就返回：`read_some` 的契约是「数据一到尽快交出」，
        // 等满 max_len 会把「同一次拉取之后才到的数据」也堵在连接上——
        // SSE 这类边到边读协议的下一个事件就卡在了一次读取里。
        // 循环只为「这批线上字节全是帧头、还没解出载荷」的情形继续。
        if filled > 0 {
          return filled
        }
      }
      filled
    }
  }
}

///|
/// 把一个数据段尽量装进目标缓冲，装不下的整个压入 pending。
/// 返回实际装入的字节数。
fn BodyReader::stash(
  self : BodyReader,
  dst : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
  piece : Bytes,
  filled : Int,
) -> Int {
  let mut i = 0
  while i < piece.length() && filled + i < max_len {
    dst[offset + filled + i] = piece[i]
    i += 1
  }
  if i < piece.length() {
    // 余量切片是「从 i 开始的新字节」，队首消费位置从 0 起算
    self.pending.push(piece[i:].to_owned())
    if self.pending.length() == 1 {
      self.pending_off = 0
    }
  }
  i
}

///|
/// 清 pending：把上次剩下的数据段按序拷进目标缓冲。
fn BodyReader::drain_pending(
  self : BodyReader,
  dst : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  let mut filled = 0
  while filled < max_len && self.pending.length() > 0 {
    let piece = self.pending[0]
    let mut i = self.pending_off
    while i < piece.length() && filled < max_len {
      dst[offset + filled] = piece[i]
      i += 1
      filled += 1
    }
    if i >= piece.length() {
      self.pending = array_tail(self.pending)
      self.pending_off = 0
    } else {
      self.pending_off = i
    }
  }
  filled
}

///|
/// 去掉数组首元素的浅拷贝（ pending 队列的出队；数组很小，不值得原地搬）。
fn array_tail(items : Array[Bytes]) -> Array[Bytes] {
  let rest = []
  for i in 1..<items.length() {
    rest.push(items[i])
  }
  rest
}
