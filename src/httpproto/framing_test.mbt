// 分帧判定的规则测试：判定顺序就是安全边界（无体 → TE → CL → close）。

///|
/// 构造头块的便捷函数：parse 一次，测试里省得逐条 append。
fn headers_of(lines : Array[String]) -> @httpproto.HeaderMap raise {
  @httpproto.parse_header_block(lines)
}

///|
/// 无体规则最先：HEAD 的任何响应、1xx / 204 / 304，不管头上写了什么都无体。
/// 「204 却带 Content-Length」是真实世界里存在的服务器 bug，按 RFC 照样无体。
test "no-body rules come first" {
  let lying = headers_of(["Content-Length: 100"])
  assert_eq(
    @httpproto.body_framing(true, 200, lying),
    @httpproto.BodyFraming::Empty,
  )
  assert_eq(
    @httpproto.body_framing(false, 100, lying),
    @httpproto.BodyFraming::Empty,
  )
  assert_eq(
    @httpproto.body_framing(false, 101, lying),
    @httpproto.BodyFraming::Empty,
  )
  assert_eq(
    @httpproto.body_framing(false, 204, lying),
    @httpproto.BodyFraming::Empty,
  )
  assert_eq(
    @httpproto.body_framing(false, 304, lying),
    @httpproto.BodyFraming::Empty,
  )
  assert_eq(
    @httpproto.body_framing(false, 200, lying),
    @httpproto.BodyFraming::Length(100),
  )
}

///|
/// TE 优先于 CL；chunked 之前的其他编码（我们不会应用）显式拒绝；
/// 最后一个编码不是 chunked 也拒绝。
test "transfer-encoding is validated and wins over content-length" {
  let chunked = headers_of(["Transfer-Encoding: chunked", "Content-Length: 5"])
  assert_eq(
    @httpproto.body_framing(false, 200, chunked),
    @httpproto.BodyFraming::Chunked,
  )
  // TE 写在多行、值带逗号段：等价摊平后仍是 chunked
  let multiline = headers_of([
    "Transfer-Encoding: gzip", "Transfer-Encoding: chunked",
  ])
  let error = try {
    ignore(@httpproto.body_framing(false, 200, multiline))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
  // 最后一个编码不是 chunked：没有解它的能力
  let no_chunked = headers_of(["Transfer-Encoding: gzip"])
  let error = try {
    ignore(@httpproto.body_framing(false, 200, no_chunked))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@httpproto.ParseError::Malformed(_)))
  // TE 大小写不敏感
  let upper = headers_of(["Transfer-Encoding: Chunked"])
  assert_eq(
    @httpproto.body_framing(false, 200, upper),
    @httpproto.BodyFraming::Chunked,
  )
}

///|
/// Content-Length：单条正常；多条 / 逗号分隔必须全部一致；
/// 不是纯数字或值不一致都是走私形状。
test "content-length consistency is enforced" {
  let single = headers_of(["Content-Length: 42"])
  assert_eq(
    @httpproto.body_framing(false, 200, single),
    @httpproto.BodyFraming::Length(42),
  )
  let repeated = headers_of(["Content-Length: 42", "Content-Length: 42"])
  assert_eq(
    @httpproto.body_framing(false, 200, repeated),
    @httpproto.BodyFraming::Length(42),
  )
  let comma = headers_of(["Content-Length: 42, 42"])
  assert_eq(
    @httpproto.body_framing(false, 200, comma),
    @httpproto.BodyFraming::Length(42),
  )
  let bad_cases : Array[(Int, Array[String])] = [
    (0, ["Content-Length: 42", "Content-Length: 43"]),
    (1, ["Content-Length: abc"]),
    (2, ["Content-Length: -5"]),
    (3, ["Content-Length: "]),
    (4, ["Content-Length: 99999999999999999999"]),
  ]
  for case in bad_cases {
    let error = try {
      ignore(@httpproto.body_framing(false, 200, headers_of(case.1)))
      None
    } catch {
      error => Some(error)
    }
    assert_true(
      error is Some(@httpproto.ParseError::Malformed(_)),
      msg="expect Malformed for CL case \{case.0}",
    )
  }
}

///|
/// 什么都没有：读到连接关闭为止。HTTP/1.0 不写 CL 是常态；1.1 这么发
/// 也只能靠关闭收尾（phase 1 每请求一条连接，接得住）。
test "no framing headers means read until close" {
  let none = headers_of([])
  assert_eq(
    @httpproto.body_framing(false, 200, none),
    @httpproto.BodyFraming::UntilClose,
  )
  assert_eq(
    @httpproto.body_framing(false, 200, headers_of(["Server: nginx"])),
    @httpproto.BodyFraming::UntilClose,
  )
}
