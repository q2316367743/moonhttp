// SSE 解析的字节级细节：扫描行尾、切字段、解析字段值。
//
// 与 sse.mbt 分开是为了守在 AGENTS.md 的单文件 300 行红线内，
// 也因为这一层可以纯粹按「字节进、字段出」来读：它不认识事件，
// 只认识行。规范里的每条规则都在这一层落成一段可以单独讲清的代码。

///|
/// 丢掉流开头的 UTF-8 BOM（规范要求）。只看流开头一次。
///
/// 字节不够判定时先不动：`0xEF` 开头的三字节序列可能是 BOM，
/// 也可能是普通字符的一部分，要凑够三个字节才能定案。
/// 只在开头处理，也就不会误伤值中间的 U+FEFF。
fn SseParser::skip_bom(self : SseParser) -> Unit {
  if self.head_done {
    return
  }
  let length = self.pending.length()
  if length == 0 {
    return
  }
  if self.pending[0].to_int() != 0xEF {
    // 开头不是 BOM 的第一个字节，可以定案了。
    self.head_done = true
    return
  }
  if length < 3 {
    // 还差字节，下次 push 再判。
    return
  }
  if self.pending[1].to_int() == 0xBB && self.pending[2].to_int() == 0xBF {
    self.pending = self.pending.exact_view(start=3).to_owned()
  }
  self.head_done = true
}

///|
/// 从 `from` 开始找一行的结束位置，返回 `(行尾下标, 行尾字节数)`。
///
/// 三种行尾都认：CRLF 是 2 个字节，单独的 LF 或 CR 是 1 个。
///
/// **CR 落在缓冲区末尾时返回 `None`**：它可能是 CRLF 的前半，
/// 现在消费掉就会把一次换行当成两次，凭空多切出一个空行——也就是一个假事件。
/// 等下一块数据到了再判定，这正是跨块安全的关键。
fn find_line_end(buf : Bytes, from : Int) -> (Int, Int)? {
  let length = buf.length()
  let mut index = from
  while index < length {
    let byte = buf[index].to_int()
    if byte == LF {
      return Some((index, 1))
    }
    if byte == CR {
      if index + 1 >= length {
        return None
      }
      if buf[index + 1].to_int() == LF {
        return Some((index, 2))
      }
      return Some((index, 1))
    }
    index = index + 1
  }
  None
}

///|
/// 把 `pending` 里所有**行尾完整**的行交给 `handle_line`，
/// 返回第一个未消费字节的位置。
///
/// 「行尾不完整」有两种：还没收到换行，以及只收到了 CRLF 的前半个 CR。
/// 两种都由 `find_line_end` 返回 `None`，这里就停手等下一块数据。
fn SseParser::consume_lines(self : SseParser) -> Int {
  let mut start = 0
  let mut progress = true
  while progress {
    match find_line_end(self.pending, start) {
      None => progress = false
      Some((terminator, step)) => {
        self.handle_line(start, terminator)
        start = terminator + step
      }
    }
  }
  start
}

///|
/// 处理 `pending[start:end]` 这一行。
fn SseParser::handle_line(self : SseParser, start : Int, end : Int) -> Unit {
  // 空行 = 事件边界，分发当前累积的事件。
  if start == end {
    self.dispatch()
    return
  }
  // `:` 开头的整行是注释，忽略。心跳常写成 `: ping`，
  // 它存在的意义就是「别让连接超时」，本身不该变成事件。
  if self.pending[start].to_int() == COLON {
    return
  }
  let (field, value_start, value_end) = self.split_field(start, end)
  // 值取成独立的一份：后面要写 `self` 的字段，不能让它一直借着 `pending`。
  let value = self.pending
    .exact_view(start=value_start, end=value_end)
    .to_owned()
  match field {
    "data" => self.data.push(value)
    "event" => self.event = @utf8.decode_lossy(value)
    // 含 U+0000 的 id 必须忽略（规范），否则重连时会把非法值
    // 塞进 `Last-Event-ID` 请求头。
    "id" =>
      if !has_nul(value) {
        self.last_id = Some(@utf8.decode_lossy(value))
      }
    "retry" =>
      match parse_retry(value) {
        Some(milliseconds) => self.retry = Some(milliseconds)
        None => ()
      }
    // 其余字段（含规范未定义的）一律忽略——规范也是这么要求的。
    _ => ()
  }
}

///|
/// 把一行切成字段名与值，返回 `(字段名, 值起点, 值终点)`。
///
/// - 第一个 `:` 之前是字段名、之后是值；
/// - 值只去掉**一个**前导空格，多出来的空格属于值本身；
/// - 整行没有 `:` 时，字段名是整行、值为空串。
fn SseParser::split_field(
  self : SseParser,
  start : Int,
  end : Int,
) -> (String, Int, Int) {
  // 只在行内找冒号：`find` 要作用在视图上，否则会从前面的行里找到冒号。
  let line = self.pending.exact_view(start~, end~)
  match line.find(b":") {
    None => (@utf8.decode_lossy(line), end, end)
    Some(colon) => {
      let mut value_start = start + colon + 1
      if value_start < end && self.pending[value_start].to_int() == SPACE {
        value_start = value_start + 1
      }
      let field = self.pending.exact_view(start~, end=start + colon)
      (@utf8.decode_lossy(field), value_start, end)
    }
  }
}

///|
/// 值里是否含 U+0000（只给 `id:` 用）。
fn has_nul(value : BytesView) -> Bool {
  for byte in value {
    if byte.to_int() == 0 {
      return true
    }
  }
  false
}

///|
/// 解析 `retry:` 的值：**必须全为 ASCII 数字**才生效，否则整体忽略。
///
/// 规范明确「其它情况忽略」，所以 `retry: 1x`、`retry: ` 都不生效，
/// 也不会把已经生效的值改掉。
fn parse_retry(value : BytesView) -> Int? {
  if value.is_empty() {
    return None
  }
  let mut result = 0
  for byte in value {
    let code = byte.to_int()
    if code < 48 || code > 57 {
      return None
    }
    if result > MAX_RETRY {
      return None
    }
    result = result * 10 + (code - 48)
  }
  Some(result)
}

///|
/// 把多条 `data:` 行的值用单个 `\n` 连接起来。
///
/// 等价于规范里「逐行把值追加到 data 缓冲再补一个 `\n`，分发前去掉最后一个 `\n`」，
/// 但不需要在每次分发时回头删字符。
fn join_lines(lines : Array[Bytes]) -> Bytes {
  let mut result = b""
  let mut index = 0
  while index < lines.length() {
    if index > 0 {
      result = result + b"\n"
    }
    result = result + lines[index]
    index = index + 1
  }
  result
}
