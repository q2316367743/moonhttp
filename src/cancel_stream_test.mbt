// 取消在流式入口（`stream` / `sse`）与上传阶段的验收用例。
//
// 前两个入口的「读一块」都经过 `ResponseBody::read_some` / `read_until`，取消在那里
// 有两个落点：读之前查 token（取消落在两次读取之间）、读之中打断挂起的 socket 动作。
// 上传的落点在发送阶段（`write_body` 的每一块都跑在可被取消的子任务里）。
//
// 请求路径的用例在 `src/cancel_test.mbt`，句柄状态机在 `src/config/cancel_test.mbt`。

///|
/// 起一个「分块吐正文、每块间隔 `delay` 毫秒」的本机 server，返回端口。
///
/// 用来制造「读了一次还在读第二次」的中间状态：取消要能停在这中间，
/// 而不是等到整份响应体读完。
async fn drip_server(
  group : @async.TaskGroup[Unit],
  chunk_count : Int,
  delay : Int,
) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((_request, _body, conn) => {
      conn..send_response(200, "OK").flush()
      for i = 0; i < chunk_count; i = i + 1 {
        conn..write_string("chunk-\{i}").flush()
        @async.sleep(delay)
      }
      conn.end_response()
    })
  }
  port
}

///|
/// 起一个「收到请求后既不读请求体、也不回响应」的本机 server，返回端口。
///
/// 上传取消的用例靠它制造挂起点：客户端一直往里写，内核缓冲写满之后写动作就挂在
/// socket 上，这时取消才有效可施（那种「执行到下一个检查点再看标志位」的实现在
/// 这里同样没有检查点）。
async fn deaf_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever() <| ((_request, _body, conn) => {
      @async.sleep(3000)
      conn..send_response(200, "OK").end_response()
    })
  }
  port
}

///|
/// 从**下载进度回调里**取消：回调跑在读全量的那个子任务里，所以取消立刻对
/// 这一段生效——下一块不会再读，错误里带的是已经读到的那部分。
///
/// 这条用例也是「取消可以从任何地方发起」的演示：`ProgressCallback` 是
/// `noraise` 的，拿不到任何返回信号，但 `cancel` 是同步函数，随手就能调。
async test "cancelling from the download progress callback stops the read" {
  @async.with_task_group() <| group => {
    let port = drip_server(group, 4, 100)
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let seen : Array[Int] = [0]
    let error = try {
      ignore(
        client.request(
          @moonhttp.Config::new("http://127.0.0.1:\{port}/drip")
          .with_cancel_token(token)
          .with_on_download_progress(fn(event) {
            // 第一次回调就取消：后面的块不该再读
            seen[0] = event.loaded
            token.cancel(message="进度回调里取消")
          }),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_true(error.is_cancelled())
    assert_eq(error.message(), "进度回调里取消")
    // 报过一次进度，但字节数不足整份响应体（4 块 × 7 字节 = 28）
    assert_true(seen[0] > 0)
    assert_true(error.response().unwrap().bytes().length() < 28)
  }
}

///|
/// 消费字节流的过程中取消：下一次读取报 `ERR_CANCELED`，**不是** `None`。
///
/// 「不是 EOF」是这条用例的重点：把取消当成读到结尾，会让
/// `while stream.read_some() is Some(_)` 安静收场，调用方以为对端正常收尾。
async test "cancel while consuming a stream reports cancelled instead of eof" {
  @async.with_task_group() <| group => {
    let port = drip_server(group, 4, 100)
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let stream = client.stream(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/drip").with_cancel_token(
        token,
      ),
    )
    // 先正常读到一块，确认取消打断的是「正在消费的流」而不是建连
    assert_true(stream.read_some().unwrap().length() > 0)
    token.cancel(message="不读了")
    let error = try {
      ignore(stream.read_some())
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_true(error.is_cancelled())
    assert_eq(error.message(), "不读了")
    // 取消顺带释放了连接；close 幂等，重复调用没有副作用
    stream.close()
    stream.close()
  }
}

///|
/// 消费 SSE 事件流的过程中取消：`next_event` 抛 `ERR_CANCELED`，同样不是 EOF
/// （返回 `None` 会被上层当成「服务端结束了事件流」，而它其实是调用方自己喊停）。
async test "cancel while consuming an sse stream reports cancelled" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, _body, conn) => {
        conn
        ..send_response(200, "OK", extra_headers=event_stream_headers())
        .flush()
        conn..write_string("data: one\r\n\r\n").flush()
        @async.sleep(3000)
        conn..write_string("data: two\r\n\r\n").end_response()
      })
    }
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let events = client.sse(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/events").with_cancel_token(
        token,
      ),
    )
    assert_eq(events.next_event().unwrap().data, "one")
    token.cancel(message="不听了")
    let error = try {
      ignore(events.next_event())
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_true(error.is_cancelled())
    assert_eq(error.message(), "不听了")
    events.close()
  }
}

///|
/// 从**上传进度回调里**取消：请求体写到一半就断，报出去的字节数远小于整个请求体。
///
/// 上传的分块写（64 KiB 一块）跑在发送阶段的同一个可取消子任务里，所以取消落在
/// 下一块写出去的挂起点上，而不是等整份 body 传完。
async test "cancelling from the upload progress callback stops the upload" {
  @async.with_task_group() <| group => {
    let port = deaf_server(group)
    // 4 MiB 的请求体：远大于内核缓冲，写动作必然挂住一次，取消才有落点
    let unit = StringBuilder()
    for i = 0; i < 1024; i = i + 1 {
      unit.write_string("x")
    }
    let body = StringBuilder()
    for i = 0; i < 4096; i = i + 1 {
      body.write_string(unit.to_string())
    }
    let payload = body.to_string()
    let token = @moonhttp.CancelToken::new()
    let client = @moonhttp.Client::new()
    let seen : Array[Int] = [0]
    let error = try {
      ignore(
        client.request(
          @moonhttp.Config::new("http://127.0.0.1:\{port}/upload")
          .with_data_from_str(payload)
          .with_cancel_token(token)
          .with_on_upload_progress(fn(event) {
            seen[0] = event.loaded
            token.cancel(message="不传了")
          }),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    let error = error.unwrap()
    assert_true(error.is_cancelled())
    assert_eq(error.message(), "不传了")
    // 传了一部分就断，没把整个请求体写完
    assert_true(seen[0] > 0)
    assert_true(seen[0] < payload.length())
  }
}

///|
/// 预检查覆盖两个流式入口（它们共用 `Client::open_stream`）：已取消的 token
/// 让 `Client::stream` / `Client::sse` 在建连之前就失败，一个请求都不发出去。
///
/// 与 `request` 的行为一致——「已取消的请求什么都不做」是三个入口共同的语义。
async test "a cancelled token fails stream and sse before connecting" {
  let token = @moonhttp.CancelToken::new()
  token.cancel(message="提前取消")
  let mock = @transport.MockTransport::new(raw_response(200, "OK", "{}"))
  let transport : &@transport.Transport = mock
  let client = @moonhttp.Client::new(transport~)
  let stream_error = try {
    ignore(
      client.stream(@moonhttp.Config::new("/bytes").with_cancel_token(token)),
    )
    None
  } catch {
    error => Some(error)
  }
  assert_true(stream_error.unwrap().is_cancelled())
  let sse_error = try {
    ignore(
      client.sse(@moonhttp.Config::new("/events").with_cancel_token(token)),
    )
    None
  } catch {
    error => Some(error)
  }
  let sse_error = sse_error.unwrap()
  assert_true(sse_error.is_cancelled())
  assert_eq(sse_error.message(), "提前取消")
  assert_eq(mock.request_count(), 0)
}
