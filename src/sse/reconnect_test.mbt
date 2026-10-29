// 自动重连要用到的解析器状态：last_id / retry 的读取与跨连接重置。
// 这些是纯逻辑，不需要接 HTTP；重连行为本身在根包 sse_reconnect_test.mbt。

///|
test "last event id and retry interval include id-only blocks" {
  let parser = @sse.SseParser::new()
  assert_eq(parser.last_event_id(), None)
  assert_eq(parser.retry_interval(), None)

  // 没有 data: 的块不产生事件，但持久状态已经更新——重连要用它们。
  parser.push(@utf8.encode("id: 42\nretry: 500\n\n"))
  assert_eq(parser.next(), None)
  assert_eq(parser.last_event_id(), Some("42"))
  assert_eq(parser.retry_interval(), Some(500))
}

///|
test "begin stream keeps id/retry and skips a new bom" {
  let parser = @sse.SseParser::new()
  parser.push(@utf8.encode("id: 7\nretry: 25\ndata: old\n\n"))
  assert_eq(parser.next().unwrap().data, "old")
  parser.finish()

  parser.begin_stream()
  // 新连接开头的 BOM 要重新丢掉；id / retry 跨连接保留。
  parser.push(b"\xEF\xBB\xBF" + @utf8.encode("data: new\n\n"))
  let event = parser.next().unwrap()
  assert_eq(event.data, "new")
  assert_eq(event.id, Some("7"))
  assert_eq(event.retry, Some(25))
}

///|
test "begin stream discards the previous stream's partial line" {
  let parser = @sse.SseParser::new()
  parser.push(@utf8.encode("data: cut"))
  parser.begin_stream()
  parser.push(@utf8.encode("data: ok\n\n"))
  assert_eq(parser.next().unwrap().data, "ok")
}
