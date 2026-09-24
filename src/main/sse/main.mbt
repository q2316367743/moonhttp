///|
/// 示例：SSE（Server-Sent Events）事件流的解析与取消。
///
/// 靶子是本机的 OpenAI 兼容服务（见 `sse_base` 与 `sse_key`），
/// 用 `stream: true` 让模型一个分片一个分片地吐，客户端逐事件打印：
///
/// 1. 主流程：打印每个事件（序号、原始 data、解析出来的增量），
///    把 `delta.reasoning`（思维链）与 `delta.content`（正文）分开累加，
///    直到收到 `data: [DONE]`；
/// 2. 流式取消：收到第 3 个分片就取消，验证「报 ERR_CANCELED 而不是安静收场」。
///
/// SSE 的关键前提是**不限时**：`timeout` 在读取阶段是「单次读取的等待上限」，
/// 模型思考时几十秒不出数据是正常的，所以本示例不给 `timeout`。
/// 用 `moon run src/main/sse` 执行。本包只是示例，不随模块发布。
let sse_base : String = "http://127.0.0.1:8910/v1"

///|
/// 本机服务的 key（本地自用，无泄漏风险；换成自己的服务时改这里）。
let sse_key : String = "sk-NgQIgUXOzPsc-IIRRJ-3RyrtDKERuCOk"

///|
/// 模型名。
let sse_model : String = "sensenova-6.8-flash-lite"

///|
/// 一条流式分片被归类成什么。
///
/// 本示例用的模型是推理模型：它先吐 `delta.reasoning`（思维链），
/// 再吐 `delta.content`（正文），末尾再补一条只带 `usage` 的分片。
enum Piece {
  Reply(String) // 正文增量
  Thinking(String) // 思维链增量
  Usage(String) // 用量统计（末尾那条 choices 为空的分片）
  Done // data: [DONE]
  Other // 角色声明、空增量等
}

///|
async fn main {
  let streaming = try {
    stream_chat()
    None
  } catch {
    error => Some(error)
  }
  match streaming {
    Some(error) => report_unreachable(error)
    None => ()
  }
  let cancelling = try {
    cancel_mid_stream()
    None
  } catch {
    error => Some(error)
  }
  match cancelling {
    Some(error) => report_unreachable(error)
    None => ()
  }
}

///|
/// 服务不可达 / 不接受 SSE 时的提示。
///
/// 最常见的两类：服务没起（`ERR_NETWORK`）、响应头没有声明
/// `Content-Type: text/event-stream`（`ERR_NOT_SUPPORT`，`Client::sse` 会拒绝）。
fn report_unreachable(error : @moonhttp.HttpError) -> Unit {
  println("  请求失败：\{error.code()} / \{error.message()}")
  match error.code() {
    @moonhttp.ErrorCode::Network =>
      println(
        "  提示：本机 SSE 服务没起？示例期望它在 \{sse_base} 上",
      )
    @moonhttp.ErrorCode::NotSupported =>
      println(
        "  提示：对方的响应头里没有 text/event-stream，`Client::sse` 会拒绝",
      )
    _ => ()
  }
  println("")
}

///|
/// 造一个流式对话请求（POST + Bearer + JSON body）。
///
/// 不给 `timeout`：SSE 的读取是按次等待，长连就该不限时（见本文件头部注释）。
fn chat_config(prompt : String) -> @moonhttp.Config {
  @moonhttp.Config::new("/chat/completions")
  .with_method(@moonhttp.Method::Post)
  .with_header("Authorization", "Bearer \{sse_key}")
  .with_header("Accept", "text/event-stream")
  .with_data_from_json({
    "model": sse_model,
    "stream": true,
    "messages": [{ "role": "user", "content": prompt }],
  })
}

///|
/// 建实例：`base_url` 是服务根，请求里只写路径。
fn sse_client() -> @moonhttp.Client {
  @moonhttp.create(@moonhttp.Config::default().with_base_url(sse_base))
}

///|
/// 1. 主流程：逐事件读，直到 `[DONE]`。
async fn stream_chat() -> Unit raise @moonhttp.HttpError {
  println("== 1. SSE 流式对话（逐事件解析）==")
  println("  目标 = \{sse_base}/chat/completions，模型 = \{sse_model}")
  let events = sse_client().sse(chat_config("用一句话介绍月亮。"))
  println(
    "  状态行 = \{events.status} \{events.status_text}，Content-Type = \{events.headers.get("content-type").unwrap_or("<无>")}",
  )
  let reply = StringBuilder()
  let thinking = StringBuilder()
  let mut count = 0
  while events.next_event() is Some(event) {
    count = count + 1
    match piece_of(event.data) {
      Reply(text) => {
        reply.write_string(text)
        println("  [\{count}] 正文 + \{text}")
      }
      Thinking(text) => {
        thinking.write_string(text)
        // 推理模型的思维链分片极多（实测同一条问题吐出过 8000 多片），
        // 逐片打印会把控制台淹没，只挑前几片看一眼，其余到最后统计。
        if count <= 3 {
          println("  [\{count}] 思考 + \{head_text(text, 40)}")
        }
      }
      Usage(text) => println("  [\{count}] 用量 = \{text}")
      Done => println("  [\{count}] 收到结束标记（data: [DONE]）")
      Other =>
        match event.event {
          // `event.event` 缺省是 "message"（OpenAI 的流不设 event 字段）
          "message" =>
            println("  [\{count}] 其它分片（角色声明 / 空增量）")
          other =>
            println(
              "  [\{count}] 事件类型 \{other}（data 长度 \{event.data.length()}）",
            )
        }
    }
  }
  println("  事件总数 = \{count}")
  println("  正文（拼出来的完整回答）= \{reply.to_string()}")
  println("  思维链共 \{thinking.to_string().length()} 字符")
  // close 幂等：读到 EOF 时连接已经关了，再关一次没有副作用
  events.close()
  events.close()
  println("")
}

///|
/// 2. 流式取消：收到第 3 个分片就取消。
///
/// 取消之后 `next_event()` 抛 `ERR_CANCELED`，**不是**返回 `None`——
/// 返回 `None` 会被上层当成「服务端正常收尾」，而实际是调用方自己喊停。
async fn cancel_mid_stream() -> Unit raise @moonhttp.HttpError {
  println("== 2. 流式取消（收到第 3 个分片就停）==")
  let token = @moonhttp.CancelToken::new()
  let events = sse_client().sse(
    chat_config("写一篇 800 字的散文。").with_cancel_token(token),
  )
  let mut count = 0
  let outcome = try {
    while events.next_event() is Some(_) {
      count = count + 1
      if count >= 3 {
        println("  已收到 \{count} 个分片，取消")
        token.cancel(message="听够了")
      }
    }
    "流正常结束（不应该：取消没生效）"
  } catch {
    error => "抛出 \{error.code()}：\{error.message()}"
  }
  println("  结果 = \{outcome}，取消前收到 \{count} 个分片")
  events.close()
  println("")
}

///|
/// 把一条事件的 `data` 归类。
///
/// OpenAI 兼容的流形如：
/// `{"choices":[{"delta":{"content":"…"},"finish_reason":""}], ...}`，
/// 末尾一条 `choices` 为空、只有 `usage`，最后再来一条 `data: [DONE]`。
fn piece_of(data : String) -> Piece {
  if data == "[DONE]" {
    return Done
  }
  let parsed : Json? = Some(@json.parse(data)) catch { _ => None }
  let fields = match parsed {
    Some(json) => if json is Object(fields) { fields } else { Map([]) }
    None => Map([])
  }
  match fields.get("choices") {
    Some(Array(choices)) =>
      match choices {
        [first, ..] =>
          match first {
            { "delta": Object(delta), .. } => delta_piece(delta)
            _ => Other
          }
        [] =>
          match fields.get("usage") {
            Some(usage) => Usage(usage.stringify())
            None => Other
          }
      }
    _ => Other
  }
}

///|
/// 从 `delta` 里取增量：正文优先，其次思维链。
fn delta_piece(delta : Map[String, Json]) -> Piece {
  match delta.get("content") {
    Some(String(text)) if text.length() > 0 => Reply(text)
    _ =>
      match delta.get("reasoning") {
        Some(String(text)) if text.length() > 0 => Thinking(text)
        _ => Other
      }
  }
}

///|
/// 取字符串的前 `limit` 个字符（不足就整体返回），思维链动辄几千字，打印前要截断。
fn head_text(text : String, limit : Int) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned() + "…"
  }
}
