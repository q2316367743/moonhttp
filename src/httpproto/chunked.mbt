// chunked 的增量解码状态机（RFC 9112 §7.1 的接收侧）。
//
// 为什么是「喂字节、吐数据段」而不是「给 Reader」：分帧是纯逻辑，
// 与 I/O 无关——TCP 一段字节可能从任何地方切开（chunk-size 行、CRLF、
// chunk 数据都要允许跨多次 feed），把它写成状态机才能用同步测试把
// 「任意切点都正确」这件事钉死（docs/17 口径 6）。I/O 驱动归 httpconn。

///|
/// 解码器的内部状态。`Done` 单列是为了让 `finish()` 能区分
/// 「正常收尾」与「连接受收但报文被截断」。
priv enum ChunkState {
  /// 正在读 chunk-size 行（含可选 `;ext` 扩展）
  Size
  /// 正在读 chunk 数据，`remaining` 记还剩多少字节
  Data
  /// chunk 数据读完，等数据后的 CRLF
  DataCrlf
  /// 终止 chunk（0）已到，正在读 trailer 节（直到空行）
  Trailer
  /// 完整报文收尾；之后再喂字节是坏流
  Done
}

///|
/// chunked 增量解码器。用法：
///
/// 1. 网络每来一段字节就 `feed` 一次，返回值是这次**解出的**数据段
///    （可能为空——来的字节都花在行/CRLF 边界上时）；
/// 2. 连接 EOF 时调 `finish`：没走到 `Done` 就是「报文被截断」，报 `Malformed`。
///
/// 两个口径（docs/17 待决问题的落地）：
/// - chunk 扩展（`;ext`）解析出来后忽略——没有客户端语义；
/// - trailer 节解析后**丢弃**——h1 场景先不透出，透出留待后续设计。
pub struct ChunkDecoder {
  priv mut state : ChunkState
  /// `Data` 状态下当前 chunk 还剩多少字节
  priv mut remaining : Int
  /// 行累积缓冲：chunk-size 行与 trailer 行都可能跨 feed，攒齐了再解析
  priv line : @buffer.Buffer
  /// `DataCrlf` 状态下已匹配的字节数（0 还没匹配，2 表示 CRLF 齐了）
  priv mut crlf_len : Int
}

///|
pub fn ChunkDecoder::new() -> ChunkDecoder {
  {
    state: Size,
    remaining: 0,
    line: @buffer.Buffer::Buffer(size_hint=16),
    crlf_len: 0,
  }
}

///|
/// 是否已经走到完整收尾（终止 chunk 与 trailer 节都处理完）。
/// 收尾之后再喂字节会报 `Malformed`。
pub fn ChunkDecoder::is_done(self : ChunkDecoder) -> Bool {
  self.state is Done
}

///|
/// 在 `input[start..]` 里找行结束（LF）。找到则把行内容（不含 CRLF）写进
/// `self.line` 并返回 `(下一个字节位置, 行内容)`；没找到则把剩余全部进缓冲、
/// 返回 `None`。行尾必须是 CRLF：攒到的行以 CR 结尾才合法，裸 LF 拒绝
/// （与 `parse_header_block` 的严格口径一致）。CRLF 拆在两次 feed 之间也能接住：
/// 前一段把 `...\r` 存进缓冲，下一段的 `\n` 恰好补上行尾。
fn ChunkDecoder::scan_line(
  self : ChunkDecoder,
  input : Bytes,
  start : Int,
) -> (Int, Bytes)? raise ParseError {
  let n = input.length()
  let mut j = start
  while j < n && input[j] != b'\n' {
    j += 1
  }
  if j >= n {
    self.line.write_bytesview(input.exact_view(start~))
    return None
  }
  self.line.write_bytesview(input.exact_view(start~, end=j))
  let line = self.line.to_bytes()
  self.line.reset()
  if line.length() == 0 || line[line.length() - 1] != b'\r' {
    raise ParseError::Malformed(
      "chunked 行缺少 CR（只接受 CRLF 行尾）",
    )
  }
  Some((j + 1, line))
}

///|
/// 解析 chunk-size 行：十六进制尺寸 + 可选 `;ext`（取 `;` 之前、行尾 CR 之前
/// 的那段）。空尺寸、非十六进制、溢出都算坏流。
fn parse_chunk_size(line : Bytes) -> Int raise ParseError {
  let end = line.length() - 1
  let mut stop = end
  for k in 0..<end {
    if line[k] == b';' {
      stop = k
      break
    }
  }
  if stop == 0 {
    raise ParseError::Malformed("chunk-size 是空值")
  }
  let mut value = 0
  for k in 0..<stop {
    let c = line[k].to_char()
    let digit = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      raise ParseError::Malformed("chunk-size 含非十六进制字符")
    }
    if value > 214748363 {
      raise ParseError::Malformed("chunk-size 超出可表示范围")
    }
    value = value * 16 + digit
  }
  value
}

///|
/// 喂入一段线上字节，返回这次解出的数据段（按序；可能为空）。
pub fn ChunkDecoder::feed(
  self : ChunkDecoder,
  input : Bytes,
) -> Array[Bytes] raise ParseError {
  let out : Array[Bytes] = []
  let n = input.length()
  let mut i = 0
  while i < n {
    match self.state {
      Size =>
        match self.scan_line(input, i) {
          None => i = n
          Some((next, line)) => {
            i = next
            let size = parse_chunk_size(line)
            if size == 0 {
              self.state = Trailer
            } else {
              self.remaining = size
              self.state = Data
            }
          }
        }
      Data => {
        // 数据段直接从输入上切，不经缓冲：这是 chunked 解码的热路径
        let take = if n - i < self.remaining { n - i } else { self.remaining }
        out.push(input.exact_view(start=i, end=i + take).to_owned())
        i += take
        self.remaining -= take
        if self.remaining == 0 {
          self.crlf_len = 0
          self.state = DataCrlf
        }
      }
      DataCrlf => {
        // 逐字节比对 CRLF：顺序不对（比如裸 LF）就是坏流
        while i < n && self.crlf_len < 2 {
          let expected : Byte = if self.crlf_len == 0 { b'\r' } else { b'\n' }
          if input[i] != expected {
            raise ParseError::Malformed("chunk 数据后缺少 CRLF")
          }
          self.crlf_len += 1
          i += 1
        }
        // CRLF 齐了回到 Size 读下一个 chunk；不迁移的话外层循环原地空转
        if self.crlf_len == 2 {
          self.state = Size
        }
      }
      Trailer =>
        match self.scan_line(input, i) {
          None => i = n
          Some((next, line)) => {
            i = next
            // 终止 chunk 之后的第一条「空行」结束 trailer 节；
            // 非空行是 trailer 头，按口径丢弃
            if line.length() == 1 {
              self.state = Done
            }
          }
        }
      Done => raise ParseError::Malformed("终止 chunk 之后还有字节")
    }
  }
  out
}

///|
/// 流结束时调用：没走到 `Done` 就是报文被截断（终止 chunk 没到连接就关了）。
/// 截断必须显式失败——把半截数据当完整响应交出去，比报错更糟。
pub fn ChunkDecoder::finish(self : ChunkDecoder) -> Unit raise ParseError {
  if self.state is Done {
    return
  }
  raise ParseError::Malformed(
    "chunked 响应被截断：终止 chunk 还没到连接就关了",
  )
}
