// 请求头块渲染的规则测试：逐字节断言线上形状，最后防线就得按字节钉。

///|
/// 便捷构造：逐条 append（绕过 parse 层的拒收，专门让渲染层自己的
/// 校验拦住坏条目——两层防线各自都要被测到）。
fn map_with(pairs : Array[(String, String)]) -> @httpproto.HeaderMap {
  let map = @httpproto.HeaderMap::new()
  for pair in pairs {
    map.append(pair.0, pair.1)
  }
  map
}

///|
/// 渲染结果的文本形式（全是 ASCII，解码即原文）。
fn wire(bytes : Bytes) -> String raise {
  @utf8.decode(bytes)
}

///|
/// 最小请求：请求行 + 终止空行，一个字节都不能差。
test "renders a minimal request" {
  let bytes = @httpproto.render_request_head("GET", "/path?q=1", headers_of([]))
  assert_eq(wire(bytes), "GET /path?q=1 HTTP/1.1\r\n\r\n")
}

///|
/// 头按条目顺序渲染；Host 与默认头都只是普通条目（排序是调用方的事）。
test "renders headers in entry order" {
  let headers = map_with([
    ("Host", "api.example.com"),
    ("Accept", "application/json"),
  ])
  let bytes = @httpproto.render_request_head("GET", "/", headers)
  assert_eq(
    wire(bytes),
    "GET / HTTP/1.1\r\nHost: api.example.com\r\nAccept: application/json\r\n\r\n",
  )
}

///|
/// 自定义方法原样进请求行——这是 docs/16 承诺的 API 形态在 wire 上的样子：
/// 大小写、拼写一字不改。
test "custom methods go into the request line verbatim" {
  let bytes = @httpproto.render_request_head(
    "PROPFIND",
    "/calendar/",
    map_with([("Depth", "0")]),
  )
  assert_eq(wire(bytes), "PROPFIND /calendar/ HTTP/1.1\r\nDepth: 0\r\n\r\n")
}

///|
/// 校验是逐字节的最后防线：方法不是 token、目标为空 / 含空白 / 含非 ASCII、
/// 头值带 CR/LF/NUL（头注入），全部在渲染前拒绝。
test "rendering validates before writing any bytes" {
  let cases : Array[(String, String, Array[(String, String)])] = [
    ("GE T", "/", []), // 方法含空格
    ("", "/", []), // 方法为空
    ("GET", "", []), // 目标为空
    ("GET", "/a b", []), // 目标含空格
    ("GET", "/路径", []), // 目标含非 ASCII
    ("GET", "/", [("X-Note", "a\nb")]), // 头值注入换行
    ("GET", "/", [("X-Note", "a\rb")]), // 头值注入 CR
    ("GET", "/", [("X Bad", "v")]), // 头名不是 token
  ]
  for case in cases {
    let (meth, target, pairs) = case
    let error = try {
      ignore(@httpproto.render_request_head(meth, target, map_with(pairs)))
      None
    } catch {
      error => Some(error)
    }
    assert_true(
      error is Some(@httpproto.ParseError::Malformed(_)),
      msg="expect Malformed for \{meth} \{target}",
    )
  }
}

///|
/// 头值里的非 ASCII 是合法的（obs-text / 实践中的裸 UTF-8），按 UTF-8 编码写出。
test "non-ascii header values are encoded as utf-8" {
  let bytes = @httpproto.render_request_head(
    "GET",
    "/",
    map_with([("X-Note", "好的")]),
  )
  // 值「好的」的 UTF-8 字节是 E5 A5 BD E7 9A 84
  assert_eq(
    bytes, b"GET / HTTP/1.1\r\nX-Note: \xe5\xa5\xbd\xe7\x9a\x84\r\n\r\n",
  )
}
