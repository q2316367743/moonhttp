// connection_reusable 的判定矩阵：版本 × Connection 头声明。
// 头值用 parse_header_block 造，保证与真实解析路径同形（大小写、OWS）。

///|
test "1.1 无声明：持久是默认，可复用" {
  let headers = @httpproto.parse_header_block([]) catch {
    _ => abort("unreachable")
  }
  assert_true(@httpproto.connection_reusable(Http11, headers))
}

///|
test "1.1 close：不可复用（大小写、OWS、逗号列表内出现都算数）" {
  for
    value in ["close", "Close", "  close  ", "keep-alive, close", "foo, CLOSE"] {
    let headers = @httpproto.parse_header_block(["Connection: " + value])
    assert_false(@httpproto.connection_reusable(Http11, headers))
  }
}

///|
test "1.1 keep-alive：显式声明等同默认，可复用" {
  let headers = @httpproto.parse_header_block(["Connection: keep-alive"])
  assert_true(@httpproto.connection_reusable(Http11, headers))
}

///|
test "1.0 无声明：默认非持久，不可复用" {
  let headers = @httpproto.parse_header_block([]) catch {
    _ => abort("unreachable")
  }
  assert_false(@httpproto.connection_reusable(Http10, headers))
}

///|
test "1.0 keep-alive：显式确认才可复用" {
  let yes = @httpproto.parse_header_block(["Connection: keep-alive"])
  assert_true(@httpproto.connection_reusable(Http10, yes))
  let listed = @httpproto.parse_header_block(["Connection: TE, keep-alive"])
  assert_true(@httpproto.connection_reusable(Http10, listed))
}

///|
test "close 与 keep-alive 并存：矛盾声明按关闭处理" {
  let headers = @httpproto.parse_header_block(["Connection: keep-alive, close"])
  assert_false(@httpproto.connection_reusable(Http10, headers))
  assert_false(@httpproto.connection_reusable(Http11, headers))
}

///|
test "多条 Connection 头：任一条带 close 即关闭（get_all 摊平）" {
  let headers = @httpproto.parse_header_block([
    "Connection: keep-alive", "Connection: close",
  ])
  assert_false(@httpproto.connection_reusable(Http11, headers))
}

///|
test "无关 token 不影响判定" {
  let headers = @httpproto.parse_header_block(["Connection: TE, upgrade"])
  assert_true(@httpproto.connection_reusable(Http11, headers))
  assert_false(@httpproto.connection_reusable(Http10, headers))
}
