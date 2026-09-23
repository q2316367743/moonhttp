// SSE 入口（`Client::sse`）与事件流（`SseStream`）的用例。
//
// 与 stream_test.mbt 分开：那边测原始字节流（下载），这边测按事件读。
// 两种协议各自一个类型、各自一套用例，正是为了让「按块读」与「按事件读」
// 不会互相串门。
//
// 解析规则本身（CRLF、字段语义、持久状态……）在 src/sse/sse_test.mbt 里，
// 那层是纯逻辑同步测试；这里只测「接到 HTTP 上之后」的部分。

///|
/// 本机 server 发 SSE 响应头时用的那组头。
/// 底层要求 `Map[CaseInsensitiveString, String]`，这里包一层避免每处都写一遍。
fn event_stream_headers() -> Map[@http.CaseInsensitiveString, String] {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers[@http.CaseInsensitiveString("Content-Type")] = "text/event-stream"
  headers
}

///|
/// SSE 端到端（Mock）：事件用 **CRLF** 分隔，`next_event` 照样解析。
///
/// 这一条正是 `read_until("\n\n")` 做不到的：CRLF 流里没有连续两个 LF，
/// 按那个分隔符会一直等下去；而解析器按规范认三种行尾。
async test "sse parses crlf separated events" {
  let (client, _) = client_with(
    sse_response("event: tick\r\ndata: 1\r\n\r\ndata: 2\r\n\r\n"),
  )
  let events = client.sse(@moonhttp.Config::new("https://example.com/events"))
  assert_eq(events.status, 200)
  assert_true(events.is_success())
  let first = events.next_event().unwrap()
  assert_eq(first.event, "tick")
  assert_eq(first.data, "1")
  assert_eq(events.next_event().unwrap().data, "2")
  assert_eq(events.next_event(), None)
}

///|
/// SSE 端到端（Mock）：心跳注释不产生事件，`id` / `retry` 是跨事件持久的状态。
async test "sse skips heartbeats and keeps id state" {
  let (client, _) = client_with(
    sse_response(
      ": keep-alive\r\n\r\nid: 9\r\nretry: 500\r\ndata: a\r\n\r\ndata: b\r\n\r\n",
    ),
  )
  let events = client.sse(@moonhttp.Config::new("https://example.com/events"))
  // 第一个事件就是 a：心跳块没有产生事件
  let first = events.next_event().unwrap()
  assert_eq(first.data, "a")
  assert_eq(first.id, Some("9"))
  assert_eq(first.retry, Some(500))
  // 持久状态跟着后面的事件一起出来，重连要用
  let second = events.next_event().unwrap()
  assert_eq(second.data, "b")
  assert_eq(second.id, Some("9"))
  assert_eq(events.next_event(), None)
}

///|
/// 流在半个事件处结束：没等到空行的事件丢弃，不补发（规范行为）。
async test "sse discards an unfinished event at eof" {
  let (client, _) = client_with(sse_response("data: complete\n\ndata: cut"))
  let events = client.sse(@moonhttp.Config::new("https://example.com/events"))
  assert_eq(events.next_event().unwrap().data, "complete")
  assert_eq(events.next_event(), None)
}

///|
/// 读了几个事件就不想读了：`close` 释放连接，重复调用安全（幂等）。
async test "sse close releases the stream and is idempotent" {
  let (client, _) = client_with(sse_response("data: 1\n\ndata: 2\n\n"))
  let events = client.sse(@moonhttp.Config::new("https://example.com/events"))
  assert_eq(events.next_event().unwrap().data, "1")
  // 只读了一个事件就结束：必须显式关闭，否则连接会一直挂着
  events.close()
  events.close()
  // 关掉之后不再有事件
  assert_eq(events.next_event(), None)
}

///|
/// 服务端没有声明 `text/event-stream` 时，`sse` 在入口处就报错。
///
/// 这是「两个协议两个类型」的关键守卫：把 JSON 或二进制按事件读只会得到
/// 一堆莫名其妙的东西，宁可响亮失败。用例顺便断言请求只发了一次、
/// 且报错发生在读 body 之前——不会把响应体当事件流瞎解。
///
/// 错误里挂着已经收到的响应（状态行与响应头），所以调用方看得见「回来的
/// 到底是什么」；body 不读（声明了别的类型就可能是任意大的二进制），
/// 想看原文得改用 `Client::stream`。
async test "sse refuses responses that are not event streams" {
  let (client, mock) = client_with(raw_response(200, "OK", "{\"a\": 1}"))
  let error = try {
    ignore(client.sse(@moonhttp.Config::new("https://example.com/json")))
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::NotSupported)
  let received = error.response().unwrap()
  assert_eq(received.status, 200)
  assert_eq(received.headers.get("content-type"), Some("application/json"))
  assert_eq(received.data, "")
  assert_eq(mock.request_count(), 1)
}

///|
/// `Content-Type` 带参数、大小写不同也认（`; charset=utf-8` 不参与判定）。
async test "sse accepts an event stream content type with parameters" {
  let (client, _) = client_with(@transport.RawResponse::{
    status: 200,
    status_text: "OK",
    headers: @transport.Headers::new().set(
      "Content-Type", "Text/Event-Stream; charset=utf-8",
    ),
    body: @transport.ResponseBody::from_bytes(@utf8.encode("data: ok\n\n")),
  })
  let events = client.sse(@moonhttp.Config::new("https://example.com/events"))
  assert_eq(events.next_event().unwrap().data, "ok")
}

///|
/// 状态码不被放行时与 `stream` 一样：先把错误体读完，再抛带响应的 `HttpError`。
async test "sse raises with the error body when status is rejected" {
  let (client, _) = client_with(
    raw_response(500, "Internal Server Error", "{\"msg\": \"boom\"}"),
  )
  let error = try {
    ignore(client.sse(@moonhttp.Config::new("https://example.com/events")))
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::BadResponse)
  assert_eq(error.response().unwrap().data, "{\"msg\": \"boom\"}")
}

///|
/// 传输层失败在 SSE 路径上同样映射成 `HttpError`。
async test "sse maps transport failures to HttpError" {
  let mock = @transport.MockTransport::failing(
    @transport.TransportError::Timeout,
  )
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let error = try {
    ignore(client.sse(@moonhttp.Config::new("https://example.com/events")))
    None
  } catch {
    error => Some(error)
  }
  assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::Timeout)
}

///|
/// SSE 长连下如果显式设了 `timeout`，事件之间的停顿会按**单次读取**的上限报超时。
///
/// 这条用例是「SSE 请用默认的不限时」这句建议的理由：超时是每次读取的等待上限，
/// 不是整条请求的总时限，但长连里「长时间没有数据」本来就是正常的。
async test "an sse stream reports a timeout while waiting for the next event" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, _body, conn) => {
        conn
        ..send_response(200, "OK", extra_headers=event_stream_headers())
        .flush()
        conn..write_string("data: only\r\n\r\n").flush()
        // 之后长时间不发数据，也不结束响应
        @async.sleep(3000)
        conn.end_response()
      })
    }
    let events = @moonhttp.Client::new().sse(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/events").with_timeout(200),
    )
    // 第一段已经在路上，能在上限内读到
    assert_eq(events.next_event().unwrap().data, "only")
    // 再等就等不到数据了，按单次读取的上限报超时
    let error = try {
      ignore(events.next_event())
      None
    } catch {
      error => Some(error)
    }
    assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::Timeout)
  }
}

///|
/// **SSE 的验收用例**：本机 server 用真实连接发 CRLF 事件，发完第一段就停顿。
///
/// 两件事同时被钉住：
/// 1. 事件切分认得 CRLF——换成 `read_until("\n\n")` 这条用例根本返回不了；
/// 2. 是边到边读，不是等响应结束才解——`assert_true(!sent_tail[0])` 要求
///    第一个事件在那 800ms 停顿期间就到手了。
///
/// 时间不限（`Config` 默认 `timeout` 是 0 = 不超时）也是 SSE 的前提：
/// 读取阶段的超时是**单次读取**的等待上限，停顿不能被当成超时。
async test "sse events arrive while a real server is still stalling" {
  let sent_tail : Array[Bool] = [false]
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, _body, conn) => {
        conn
        ..send_response(200, "OK", extra_headers=event_stream_headers())
        .flush()
        conn..write_string("data: first\r\n\r\n").flush()
        // 停顿必须足够长，避免把「读得慢」误判成「不是逐段读」
        @async.sleep(800)
        sent_tail[0] = true
        conn..write_string("data: second\r\n\r\n").end_response()
      })
    }
    let events = @moonhttp.Client::new().sse(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/events"),
    )
    assert_eq(events.status, 200)
    let first = events.next_event().unwrap()
    assert_eq(first.event, "message")
    assert_eq(first.data, "first")
    // 第一段必须是在停顿期间拿到的
    assert_true(!sent_tail[0])
    assert_eq(events.next_event().unwrap().data, "second")
    assert_eq(events.next_event(), None)
  }
}
