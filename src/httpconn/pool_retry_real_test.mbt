// 连接池的真连接用例（二）：坏连接重试、上限、空闲过期、禁池与
// 用户显式 close。docs/17 分期表第 2 期「取用时坏连接重试一次」的端到端证据。

///|
/// 借来的连接被对端悄悄关掉：下一个请求**透明**换新连接重试一次，
/// 调用方只看到成功。这是池最核心的兜底。
async test "stale pooled connection is transparently retried once" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      // 对端经典死法：响应完停一小会就关——客户端此刻多半刚把连接还进池
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        @async.sleep(50)
        tcp.close()
      }
      true
    })
    let t = pooled_transport()
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"ok")
    // 等 conn 1 确定死透（50ms 关闭 + 一拍余量）
    @async.sleep(300)
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"ok")
    // 第一次尝试打在死连接上，重试换到新连接：2 条连接、2 个请求
    assert_eq(counts.conns, 2)
    assert_eq(counts.requests, 2)
  }
}

///|
/// 流式请求体不可回卷：死连接上的失败**不**重试，直接以 Network 报错——
/// 重试等于换一份内容上传，宁可失败。
async test "streaming body is not retried on a stale connection" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        @async.sleep(50)
        tcp.close()
      }
      true
    })
    let t = pooled_transport()
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"ok")
    @async.sleep(300)
    let reader : &@io.Reader = @io.MemoryReader() <| writer => {
      writer.write(b"payload")
    }
    let error = try {
      ignore(
        send_with(
          t,
          port,
          body=Some(
            @transport.RequestBody::Stream({ reader, content_length: Some(7), }),
          ),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    assert_true(error is Some(@transport.TransportError::Network(_)))
    // 没有重试：第二个请求从未被任何连接收到
    assert_eq(counts.requests, 1)
    assert_eq(counts.conns, 1)
  }
}

///|
/// 空闲超时：入池超过 idle_timeout 的连接在取用时被丢弃（惰性过期，
/// 客户端侧主动关闭），下一个请求拨新连接。
async test "idle timeout expires pooled connections" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      true
    })
    let t = transport_with(max_idle=4, idle_timeout=100)
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"ok")
    @async.sleep(300)
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"ok")
    assert_eq(counts.conns, 2)
    assert_eq(counts.requests, 2)
    // 过期连接由客户端在取用时关闭
    @async.sleep(100)
    assert_eq(counts.client_closes, 1)
  }
}

///|
/// 每 host 空闲上限：两个并发请求各占一条连接，第二条还池时超额被关
/// （服务端观察到恰好一条被客户端先关）；随后顺序请求复用幸存者。
async test "idle cap closes the surplus connection" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      true
    })
    let t = transport_with(max_idle=1, idle_timeout=30_000)
    let ta = group.spawn(() => {
      let r = send_with(t, port)
      r.body.read_all()
    })
    let tb = group.spawn(() => {
      let r = send_with(t, port)
      r.body.read_all()
    })
    assert_eq(ta.wait(), b"ok")
    assert_eq(tb.wait(), b"ok")
    assert_eq(counts.conns, 2)
    // 并发场景池是空的，两条都是新拨；还池时只留得住 1 条
    @async.sleep(100)
    assert_eq(counts.client_closes, 1)
    let r3 = send_with(t, port)
    assert_eq(r3.body.read_all(), b"ok")
    // 幸存者被复用，连接总数不变
    assert_eq(counts.conns, 2)
    assert_eq(counts.requests, 3)
  }
}

///|
/// 禁池（max_idle_per_host = 0）：行为退回 phase 1——每请求一条连接、
/// 线上恢复 `Connection: close` 声明、响应读完即关。
async test "disabled pool keeps phase 1 wire behavior" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      true
    })
    let t = transport_with(max_idle=0, idle_timeout=30_000)
    let r1 = send_with(t, port)
    assert_eq(r1.body.read_all(), b"ok")
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"ok")
    assert_eq(counts.conns, 2)
    assert_eq(counts.requests, 2)
    assert_true(head_has_connection(counts.seen_heads[0], "close"))
    assert_true(head_has_connection(counts.seen_heads[1], "close"))
    @async.sleep(100)
    assert_eq(counts.client_closes, 2)
  }
}

///|
/// 用户显式声明 `Connection: close`：请求头原样落线（set_if_absent 让用户赢），
/// 且这条响应的连接不回池——逐请求禁复用的出口。
async test "user-declared connection close opts out of the pool per request" {
  @async.with_task_group() <| group => {
    let counts = PoolServerCounts::new()
    let port = ka_server(group, counts, (tcp, _head, _index) => {
      tcp.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      true
    })
    let t = pooled_transport()
    let r1 = send_with(
      t,
      port,
      headers=@transport.Headers::new().set("Connection", "close"),
    )
    assert_eq(r1.body.read_all(), b"ok")
    @async.sleep(100)
    // 用户要关的连接，客户端读完即关，服务端观察到
    assert_eq(counts.client_closes, 1)
    let r2 = send_with(t, port)
    assert_eq(r2.body.read_all(), b"ok")
    assert_eq(counts.conns, 2)
    assert_true(head_has_connection(counts.seen_heads[0], "close"))
    // 第二个请求没带头：池启用时不发 Connection
    assert_false(head_has_any_connection(counts.seen_heads[1]))
  }
}
