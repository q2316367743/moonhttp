// 状态行与头块解析的规则测试。非法形状与合法形状等权重：
// 解析器是 trust boundary，宽松一分就是走私一分。

///|
/// 标准状态行：1.0 / 1.1、reason 可空、reason 自带空格原样保留。
test "status line happy paths" {
  let ok = @httpproto.parse_status_line("HTTP/1.1 200 OK")
  assert_eq(ok.version, @httpproto.HttpVersion::Http11)
  assert_eq(ok.code, 200)
  assert_eq(ok.reason, "OK")
  let no_reason = @httpproto.parse_status_line("HTTP/1.1 204")
  assert_eq(no_reason.code, 204)
  assert_eq(no_reason.reason, "")
  let spaced = @httpproto.parse_status_line(
    "HTTP/1.0 404 Not Found (from cache)",
  )
  assert_eq(spaced.version, @httpproto.HttpVersion::Http10)
  assert_eq(spaced.code, 404)
  assert_eq(spaced.reason, "Not Found (from cache)")
}

///|
/// 版本边界：HTTP/1.x 之外的版本是**能力边界**（Unsupported），
/// 不是语法错误——两类错误对外映射成不同的错误码。
/// 版本段按「第一个空格之前」整段比对，所以 `HTTP/1.1:200` 这种拼接
/// 也落在 Unsupported 而不是被当成 1.1。
test "unsupported versions are told apart from garbage" {
  for line in ["HTTP/2 200 OK", "HTTP/1.2 200", "HTTP/1.1:200 OK"] {
    let error = try {
      ignore(@httpproto.parse_status_line(line))
      None
    } catch {
      error => Some(error)
    }
    assert_true(
      error is Some(@httpproto.ParseError::Unsupported(_)),
      msg="expect Unsupported for \{line}",
    )
  }
  for line in ["garbage", "http/1.1 200 OK"] {
    let error = try {
      ignore(@httpproto.parse_status_line(line))
      None
    } catch {
      error => Some(error)
    }
    assert_true(
      error is Some(@httpproto.ParseError::Malformed(_)),
      msg="expect Malformed for \{line}",
    )
  }
}

///|
/// 状态行的严格形状：缺空格、状态码不是三位数字、code 后不是空格、
/// 裸 CRLF，全都拒绝。
test "status line rejects malformed shapes" {
  let malformed = [
    "HTTP/1.1", // 没有状态码段
     "HTTP/1.1 2OO OK", // 字母混进状态码
     "HTTP/1.1 20", // 不足三位
     "HTTP/1.1 2000", // 超过三位（第 4 位前缺空格）
     "HTTP/1.1 200OK", // code 后缺空格
     "HTTP/1.1 200\r", // 行内裸 CR
  ]
  for line in malformed {
    let error = try {
      ignore(@httpproto.parse_status_line(line))
      None
    } catch {
      error => Some(error)
    }
    assert_true(
      error is Some(@httpproto.ParseError::Malformed(_)),
      msg="expect Malformed for \{line}",
    )
  }
}

///|
/// 头块基础：名字原样保留、值两侧 OWS 裁掉、同名重复全部保留。
test "header block parses names, values and duplicates" {
  let map = @httpproto.parse_header_block([
    "Content-Type:  application/json  ", "X-Trace: a", "X-Trace: b",
  ])
  assert_eq(map.get_first("content-type"), Some("application/json"))
  assert_eq(map.get_all("X-Trace"), ["a", "b"])
  // 值内部的空白不动
  let inner = @httpproto.parse_header_block(["X-Note: a  b"])
  assert_eq(inner.get_first("X-Note"), Some("a  b"))
}

///|
/// obs-fold：以 SP/HTAB 开头的行折回上一行，衔接处用单个空格；
/// 连续多行续行也折叠进同一条。
test "obs-fold lines are joined with a single space" {
  let map = @httpproto.parse_header_block([
    "X-Long: first", " second", "\tthird",
  ])
  assert_eq(map.get_first("X-Long"), Some("first second third"))
  assert_eq(map.length(), 1)
}

///|
/// obs-fold 的非法位置（块首）与普通非法形状：块首续行、缺冒号、
/// 冒号前有空白（走私形状，RFC 9112 §5.1）、块中空行、裸 CRLF、非法头名。
test "header block rejects malformed shapes" {
  let cases : Array[(Array[String], String)] = [
    ([" cont"], "首行就是续行"),
    (["NoColon here"], "缺冒号"),
    (["X-Bad : v"], "冒号前有空白"),
    (["Name", "X-Ok: v"], "缺冒号排在前面"),
    (["X-A: 1", "", "X-B: 2"], "块中间出现空行"),
    (["X-Bad\r: v"], "裸 CR"),
    (["X Ws: v"], "头名含空格"),
  ]
  for case in cases {
    let error = try {
      ignore(@httpproto.parse_header_block(case.0))
      None
    } catch {
      error => Some(error)
    }
    assert_true(
      error is Some(@httpproto.ParseError::Malformed(_)),
      msg="expect Malformed for \{case.1}",
    )
  }
}

///|
/// 空头块是合法的（响应可以一条头都没有）。
test "empty header block is allowed" {
  let map = @httpproto.parse_header_block([])
  assert_eq(map.length(), 0)
}
