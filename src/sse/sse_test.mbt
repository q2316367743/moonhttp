// SSE 解析的规则用例。全部是同步测试：解析器只吃字节、不碰网络，
// 所以规范里的每条规则都能在这里逐条钉死。
//
// 这些用例的存在理由：`read_until("\n\n")` 那种「找连续两个 LF」的做法
// 在 CRLF 流上永远匹配不到（第一组用例就是钉这件事），而且它根本
// 不解析 `event:` / `data:` 字段——SSE 支持的全部内容都在这份文件里。

///|
/// 把一段文本一次性喂给解析器，再声明流结束，取出全部事件。
///
/// 结尾调 `finish()` 是必须的：末尾那个 CR 要等「不会再有 LF 了」才能定性。
fn sse_parse_all(text : String) -> Array[@sse.SseEvent] {
  let parser = @sse.SseParser::new()
  parser.push(@utf8.encode(text))
  parser.finish()
  sse_drain(parser)
}

///|
/// 取出解析器里已经攒好的全部事件（`push` 之后调）。
fn sse_drain(parser : @sse.SseParser) -> Array[@sse.SseEvent] {
  let events : Array[@sse.SseEvent] = []
  let mut running = true
  while running {
    match parser.next() {
      Some(event) => events.push(event)
      None => running = false
    }
  }
  events
}

///|
/// 只带 data 的事件：没有 id / retry 出现过，所以那两项是 `None`。
fn sse_message(data : String) -> @sse.SseEvent {
  { event: "message", data, id: None, retry: None, }
}

///|
/// 三种行尾都是合法的事件边界。
///
/// CRLF 这一条是重点：CRLF 流上事件边界的字节是 `0D 0A 0D 0A`，
/// 里面没有连续两个 `0A`，所以 `read_until("\n\n")` 永远等不到。
test "all three line endings delimit an event" {
  let expected = [sse_message("x")]
  assert_eq(sse_parse_all("data: x\n\n"), expected)
  assert_eq(sse_parse_all("data: x\r\n\r\n"), expected)
  assert_eq(sse_parse_all("data: x\r\r"), expected)
}

///|
/// 事件被切成多块喂进来也还是一个事件；只有等到空行才分发。
test "an event split across chunks is still one event" {
  let parser = @sse.SseParser::new()
  parser.push(@utf8.encode("data: he"))
  assert_eq(sse_drain(parser), [])
  // 只有换行、还没有空行：仍然不该有事件
  parser.push(@utf8.encode("llo\n"))
  assert_eq(sse_drain(parser), [])
  parser.push(@utf8.encode("\n"))
  assert_eq(sse_drain(parser), [sse_message("hello")])
}

///|
/// CRLF 被切在中间时不能提前把 CR 当成行尾。
///
/// 提前消费会让一次换行被当成两次，凭空多切出一个空行——也就是一个假事件。
test "a cr at a chunk boundary is not two line endings" {
  let parser = @sse.SseParser::new()
  parser.push(@utf8.encode("data: a\r"))
  assert_eq(sse_drain(parser), [])
  parser.push(@utf8.encode("\r\ndata: b\r\n\r\n"))
  assert_eq(sse_drain(parser), [sse_message("a"), sse_message("b")])
}

///|
/// 同一个事件里多条 `data:` 行用 `\n` 连接，且不带末尾换行。
test "multiple data lines are joined with a newline" {
  assert_eq(sse_parse_all("data: one\ndata: two\n\n"), [sse_message("one\ntwo")])
  // `data:` 写了空值算「有一行 data」，事件照发，data 是空串
  assert_eq(sse_parse_all("data:\n\n"), [sse_message("")])
}

///|
/// 注释行整行忽略。心跳就是这种行（`: ping`），它不该变成事件，
/// 也不该污染当前事件的 data 缓冲。
test "comment lines are ignored" {
  assert_eq(sse_parse_all(": ping\n\ndata: x\n\n"), [sse_message("x")])
  assert_eq(sse_parse_all("data: x\n: mid\n\n"), [sse_message("x")])
}

///|
/// 一个块里没出现过 `data:` 就不发事件——只有 `id:` / `retry:` 的块属于这种。
test "a block without data produces no event" {
  assert_eq(sse_parse_all("id: 7\nretry: 1000\n\n"), [])
  assert_eq(sse_parse_all("unknown: v\n\n"), [])
}

///|
/// 行内没有冒号时，字段名是整行、值是空串。
test "a field without a colon has an empty value" {
  // `data` 没有冒号 → 值空串，仍算一行 data
  assert_eq(sse_parse_all("data\n\n"), [sse_message("")])
  // 未知字段照样忽略
  assert_eq(sse_parse_all("nonsense\n\n"), [])
}

///|
/// 冒号后只去掉**一个**前导空格，多出来的空格属于值本身。
test "only one leading space is stripped from a value" {
  assert_eq(sse_parse_all("data:  two\n\n"), [sse_message(" two")])
  assert_eq(sse_parse_all("data:two\n\n"), [sse_message("two")])
}

///|
/// `event:` 决定事件类型，缺省是 `message`；它只对当前块有效。
test "event type defaults to message and resets per block" {
  let named = sse_parse_all("event: ping\ndata: x\n\n")
  assert_eq(named.length(), 1)
  assert_eq(named[0].event, "ping")
  let mixed = sse_parse_all("event: ping\ndata: x\n\ndata: y\n\n")
  assert_eq(mixed.length(), 2)
  assert_eq(mixed[1].event, "message")
}

///|
/// `id` 与 `retry` 是跨事件持久的解析器状态：出现过之后跟着每个事件一起出去。
/// 断线重连要用这两个值，本项目不自动重连，所以必须在事件上给到。
test "id and retry persist across events" {
  let events = sse_parse_all(
    "id: 42\nretry: 3000\ndata: first\n\ndata: second\n\n",
  )
  assert_eq(events.length(), 2)
  assert_eq(events[0].id, Some("42"))
  assert_eq(events[0].retry, Some(3000))
  assert_eq(events[1].id, Some("42"))
  assert_eq(events[1].retry, Some(3000))
}

///|
/// 含 U+0000 的 `id` 必须整条忽略（规范），否则重连时会把非法值
/// 塞进 `Last-Event-ID` 请求头。
///
/// NUL 用字节拼进去而不是写进字符串字面量：这里要的是**字节**层面的 0。
test "an id containing a null character is ignored" {
  let parser = @sse.SseParser::new()
  parser.push(@utf8.encode("id: a") + b"\x00" + @utf8.encode("b\ndata: x\n\n"))
  let events = sse_drain(parser)
  assert_eq(events.length(), 1)
  assert_eq(events[0].id, None)
}

///|
/// `retry:` 必须全是 ASCII 数字才生效，否则整个值忽略（规范）。
test "retry only takes effect when it is all digits" {
  assert_eq(sse_parse_all("retry: 1x\ndata: x\n\n")[0].retry, None)
  assert_eq(sse_parse_all("retry:\ndata: x\n\n")[0].retry, None)
  assert_eq(sse_parse_all("retry: 250\ndata: x\n\n")[0].retry, Some(250))
  // 超出范围也忽略（而不是溢出成别的数）：规范允许实现丢弃过大的重连间隔
  assert_eq(sse_parse_all("retry: 9999999999\ndata: x\n\n")[0].retry, None)
}

///|
/// 流开头的 UTF-8 BOM 忽略；BOM 自己也被切在中间时同样要处理。
test "a leading utf-8 bom is ignored" {
  let parser = @sse.SseParser::new()
  // 空块（读到 0 字节）不该改变任何状态
  parser.push(b"")
  parser.push(b"\xEF")
  // 只有一个字节，还判不出是不是 BOM，先不动
  assert_eq(sse_drain(parser), [])
  parser.push(b"\xBB\xBF" + @utf8.encode("data: x\n\n"))
  assert_eq(sse_drain(parser), [sse_message("x")])
}

///|
/// 没有空行收尾的事件块不算数（规范：流结束前没完成的事件丢弃）。
test "an event is only dispatched at a blank line" {
  assert_eq(sse_parse_all("data: x"), [])
  assert_eq(sse_parse_all("data: x\n"), [])
  assert_eq(sse_parse_all("data: x\n\n"), [sse_message("x")])
  // 末尾那半个事件丢掉，前面已完成的照常给
  assert_eq(sse_parse_all("data: x\n\ndata: y"), [sse_message("x")])
}

///|
/// 一个字符一个字节地喂：多字节 UTF-8 被切碎也不能解出乱码。
///
/// 解析器只在**整行**到手后才解码，所以字节被切在字符中间是安全的。
test "multibyte characters survive byte-by-byte feeding" {
  let parser = @sse.SseParser::new()
  let payload = @utf8.encode("event: 事件\ndata: 中文\n\n")
  let mut index = 0
  while index < payload.length() {
    parser.push(payload.exact_view(start=index, end=index + 1).to_owned())
    index = index + 1
  }
  let events = sse_drain(parser)
  assert_eq(events.length(), 1)
  assert_eq(events[0].event, "事件")
  assert_eq(events[0].data, "中文")
}

///|
/// 以裸 CR 收尾的流：末尾那个 CR 要等 `finish` 才能定性——在那之前它
/// 还可能是 CRLF 的前半。这就是 `SseParser::finish` 存在的唯一理由。
test "a trailing carriage return is settled by finish" {
  let parser = @sse.SseParser::new()
  parser.push(@utf8.encode("data: x\r\r"))
  assert_eq(sse_drain(parser), [])
  parser.finish()
  assert_eq(sse_drain(parser), [sse_message("x")])
}

///|
/// 流结束时未完成的事件丢弃：已经读到的 `data:` 行不会变成事件。
test "an unfinished block at eof is discarded" {
  let parser = @sse.SseParser::new()
  // 一行完整的 data，后面没有空行
  parser.push(@utf8.encode("data: x\n"))
  parser.finish()
  assert_eq(sse_drain(parser), [])
  // finish 之后再来数据也不该把旧块补成事件
  parser.push(@utf8.encode("\n"))
  assert_eq(sse_drain(parser), [])
}

///|
/// 一次 `push` 带来多个事件时全部攒住，按顺序交给 `next`。
test "one chunk can carry several events" {
  assert_eq(sse_parse_all("data: 1\n\ndata: 2\n\ndata: 3\n\n"), [
    sse_message("1"),
    sse_message("2"),
    sse_message("3"),
  ])
}
