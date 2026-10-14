// 响应侧：读状态行 + 头块，判定分帧。解析本身全在 httpproto（同步可测），
// 这里只负责「从连接上一行行拿」与 1xx 的跳过。

///|
/// 1xx 临时响应（100 Continue / 103 Early Hints 等）的跳过上限：
/// 我们不发 `Expect`，正常服务器根本不会发 1xx；上限只是防恶意循环。
const MAX_INTERIM_RESPONSES : Int32 = 5

///|
/// 坏连接信号：对端在**响应开始之前**就把连接关了（或写请求时对端已死）。
/// 只在取自池的连接上它才值得重试（docs/17 分期表：取用时坏连接重试一次），
/// 重试资格的裁决在 send_head；新建连接上的同款失败在这里统一翻成
/// `Network`——对端断开是网络失败，不是「收到了坏响应」（ERR_BAD_RESPONSE
/// 应该留给「真的收到了坏字节」）。
priv suberror StaleConnection {
  StaleConnection(String)
}

///|
/// 响应头读取结果。`headers` 保留**协议层的 multimap**——分帧判定要看
/// 全部 `Content-Length`（多条不一致是走私形状），压平成单值是 send 的收尾活。
/// `version` 参与复用判定：1.0 的持久连接要显式确认（docs/21）。
priv struct ResponseHead {
  version : @httpproto.HttpVersion
  code : Int32
  reason : String
  headers : @httpproto.HeaderMap
}

///|
/// 读响应头。1xx 响应（含各自的头块）读掉后继续等最终响应。
/// 解析失败以 `ParseError` 表达（Malformed / Unsupported）；
/// 对端在响应开始前关闭以 `StaleConnection` 表达——两者都由 send 统一映射。
async fn read_response_head(conn : Connection) -> ResponseHead {
  let mut interim = 0
  while true {
    // 首个状态行的读取单独兜：干净 EOF 与读取失败（对端 RST 等）都意味着
    // 一个响应字节都没到——借来的连接早死了是常态，按坏连接表达，
    // 重试资格由 send_head 裁决；从这里起响应已开始，失败一律 Malformed。
    let line = conn.read_until("\r\n") catch {
      error =>
        raise StaleConnection("连接在响应开始前失效：\{error}")
    }
    let line = match line {
      Some(line) => line
      None => raise StaleConnection("连接在响应开始前被对端关闭")
    }
    let status = @httpproto.parse_status_line(line)
    if status.code >= 200 {
      let headers = read_header_block(conn)
      return {
        version: status.version,
        code: status.code,
        reason: status.reason,
        headers,
      }
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
/// 从这里起响应已经开始：EOF 一律是 `Malformed`（半截响应不可重试）。
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
