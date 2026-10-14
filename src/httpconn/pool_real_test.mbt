// 连接池的真连接用例（一）：复用的正路与「毒化」的各条出口。
// 契约：响应体消费完才回池；截断 / 半途放弃 / 取消 / 服务端声明关闭 /
// HTTP/1.0 未确认 keep-alive，一律不回池（docs/17 口径 4、docs/21）。

///|
/// 复用的正路：两次顺序请求落同一条连接，Content-Length 与 chunked
/// 两种分帧都可复用；池启用时请求不带 Connection 头（1.1 默认持久）。
async test "pooled transport serves two requests on one connection" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      if counts.requests == 1 {
        tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
      } else {
        // 第二次换 chunked 分帧：正常收尾的 chunked 同样可复用
        tcp.write(
          b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nworld\r\n0\r\n\r\n",
        )
      }
      true
    })
    let t = pooled_transport()
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"hello")
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"world")
    assert_eq(counts.conns, 1)
    assert_eq(counts.requests, 2)
    // 池启用时不发 Connection 头（docs/21：对齐 Go / Python / Node）
    assert_false(head_has_any_connection(counts.seen_heads[0]))
    assert_false(head_has_any_connection(counts.seen_heads[1]))
  }
}

///|
/// 服务端声明 close：响应照常交付，但连接不回池——下一个请求拨新连接。
async test "server-declared close forces a fresh connection" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(
        b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok",
      )
      false
    })
    let t = pooled_transport()
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"ok")
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"ok")
    assert_eq(counts.conns, 2)
    assert_eq(counts.requests, 2)
  }
}

///|
/// HTTP/1.0 响应且没有 keep-alive 确认：服务端默认要关，客户端不回池，
/// 读完主动关连接（服务端观察到对端先关）。
async test "http/1.0 without keep-alive is not pooled" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok")
      true
    })
    let t = pooled_transport()
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"ok")
    @async.sleep(100)
    assert_eq(counts.client_closes, 1)
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"ok")
    assert_eq(counts.conns, 2)
  }
}

///|
/// 定长体被截断（声明 20 只到 5 字节就 EOF）：已到的字节照旧交出
/// （phase 1 的 EOF 交付语义不变），但这条连接死了，绝不回池。
async test "truncated content-length body poisons the connection" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, index) => {
      if index == 1 {
        tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nshort")
        false
      } else {
        tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        true
      }
    })
    let t = pooled_transport()
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"short")
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"ok")
    assert_eq(counts.conns, 2)
    assert_eq(counts.requests, 2)
  }
}

///|
/// 半途放弃：读了 5 字节就 close()。连接立即被客户端关闭（服务端观察到），
/// 不回池。
async test "abandoned body is closed and not pooled" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world")
      true
    })
    let t = pooled_transport()
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_some(max_len=5), Some(b"hello"))
    r1.body.close()
    @async.sleep(100)
    assert_eq(counts.client_closes, 1)
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"hello world")
    assert_eq(counts.conns, 2)
  }
}

///|
/// 取消毒化：读了两字节后取消，下一次读取报 Cancelled，
/// 连接已被「取消即关闭」登记毒化，不回池。
async test "cancelled body read poisons the connection" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world")
      true
    })
    let t = pooled_transport()
    let controller = @abort.AbortController::new()
    let r1 = send_with(t, port, signal=Some(controller.signal()))
    assert_eq(r1.body.read_some(max_len=2), Some(b"he"))
    controller.abort(reason="done")
    let error = try {
      ignore(r1.body.read_some())
      None
    } catch {
      error => Some(error)
    }
    assert_true(error is Some(@transport.TransportError::Cancelled(_)))
    @async.sleep(100)
    assert_eq(counts.client_closes, 1)
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"hello world")
    assert_eq(counts.conns, 2)
  }
}
