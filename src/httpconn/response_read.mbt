// 响应侧：读状态行 + 头块，判定分帧。解析本身全在 httpproto（同步可测），
// 这里只负责「从连接上一行行拿」与 1xx 的跳过。

///|
/// 1xx 临时响应（100 Continue / 103 Early Hints 等）的跳过上限：
/// 我们不发 `Expect`，正常服务器根本不会发 1xx；上限只是防恶意循环。
const MAX_INTERIM_RESPONSES : Int = 5

///|
/// 响应头读取结果。`headers` 保留**协议层的 multimap**——分帧判定要看
/// 全部 `Content-Length`（多条不一致是走私形状），压平成单值是 send 的收尾活。
priv struct ResponseHead {
  code : Int
  reason : String
  headers : @httpproto.HeaderMap
}

///|
/// 读响应头。1xx 响应（含各自的头块）读掉后继续等最终响应。
/// 所有失败都以 `ParseError` 表达（Malformed / Unsupported），
/// 映射成 @transport.TransportError 由 send 统一做。
async fn read_response_head(conn : Connection) -> ResponseHead {
  let mut interim = 0
  while true {
    let line = match conn.read_until("\r\n") {
      Some(line) => line
      None =>
        raise @httpproto.ParseError::Malformed("连接关闭，响应头缺失")
    }
    let status = @httpproto.parse_status_line(line)
    if status.code >= 200 {
      let headers = read_header_block(conn)
      return { code: status.code, reason: status.reason, headers, }
    }
    // 1xx：读掉它的头块再等真正的响应
    interim += 1
    if interim > MAX_INTERIM_RESPONSES {
      raise @httpproto.ParseError::Malformed(
        "1xx 临时响应超过 \{MAX_INTERIM_RESPONSES} 个",
      )
    }
    discard_head_block(conn)
  }
  // 循环只能从 return / raise 离开；这行只为满足类型检查
  fail("unreachable")
}

///|
/// 读头块直到空行，交给 httpproto 解析（obs-fold、多值、校验都在那）。
async fn read_header_block(conn : Connection) -> @httpproto.HeaderMap {
  let lines : Array[String] = []
  while true {
    let line = conn.read_until("\r\n")
    if line is None {
      raise @httpproto.ParseError::Malformed("头块被截断")
    }
    if line is Some("") {
      break
    }
    lines.push(line.unwrap())
  }
  @httpproto.parse_header_block(lines)
}
