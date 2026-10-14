// 连接池真连接用例的共享夹具：keep-alive 计数 server + 客户端发送助手。
//
// 与 stream_real_test 的 raw_server 的差别：raw_server 每条连接只服务一次、
// 由用例自己写响应；这里要验「连接复用」，server 必须**循环读请求**，
// 并把「服务端视角的事实」记下来——accept 了几个连接、收到几个请求、
// 有几条连接被客户端先关、每个请求头块长什么样。断言全部落在服务端
// 视角，客户端侧的池状态不可见也不必可见。

///|
/// 服务端视角的计数器。结构体引用语义，跨任务共享安全（单线程协作式，
/// 计数增减之间没有 await 点）。
struct PoolServerCounts {
  /// accept 过的连接总数
  mut conns : Int32
  /// 收到过的完整请求总数
  mut requests : Int32
  /// 观察到「对端先关」的连接数（池丢弃过期连接、毒化、禁池关闭都算）
  mut client_closes : Int32
  /// 每个请求的头块原始行（按到达顺序）
  seen_heads : Array[Array[String]]
}

///|
fn PoolServerCounts::new() -> PoolServerCounts {
  { conns: 0, requests: 0, client_closes: 0, seen_heads: [], }
}

///|
/// keep-alive 计数 server：每条连接循环服务请求，直到对端关闭或
/// `handle` 返回 false（服务端随后主动关，模拟「响应完就关」的对端）。
/// `handle(tcp, head, conn_index)` 负责写响应；head 是该请求的头块原始行。
async fn ka_server(
  group : @async.TaskGroup[Unit],
  counts : PoolServerCounts,
  handle : async (@socket.Tcp, Array[String], Int32) -> Bool,
) -> Int32 {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    while true {
      // 自管 accept 循环：accept 到的 Tcp 归本任务所有，转手交给
      // 每连接任务长期持有——run_forever 的回调一返回就会关掉连接，
      // 撑不起「先还池、连接还开着」的复用场景。
      let (tcp, _addr) = server.accept()
      counts.conns = counts.conns + 1
      let conn_index = counts.conns
      // 每连接一个任务：并发连接互不阻塞 accept 循环。
      // 客户端中途消失（RST）不该掀翻整个用例，失败静默。
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        serve_conn(counts, tcp, conn_index, handle)
      }
    }
  }
  port
}

///|
async fn serve_conn(
  counts : PoolServerCounts,
  tcp : @socket.Tcp,
  conn_index : Int32,
  handle : async (@socket.Tcp, Array[String], Int32) -> Bool,
) -> Unit {
  while true {
    let head = read_request_head(tcp)
    if head.length() == 0 {
      // EOF：对端先关了连接。池的「丢弃 / 毒化 / 禁池」三处关闭都会走到这。
      counts.client_closes = counts.client_closes + 1
      return
    }
    counts.requests = counts.requests + 1
    counts.seen_heads.push(head)
    let keep = handle(tcp, head, conn_index)
    if !keep {
      tcp.close()
      return
    }
  }
}

///|
/// 读一个请求头块（请求行 + 头行，到空行为止），原样返回各行。
async fn read_request_head(tcp : @socket.Tcp) -> Array[String] {
  let lines : Array[String] = []
  while true {
    match tcp.read_until("\r\n") {
      None => return lines
      Some("") => return lines
      Some(line) => lines.push(line)
    }
  }
  lines
}

///|
/// 池缺省配置的传输（每 host 4 条空闲、30 秒保活——测试窗口内等于不超时）。
fn pooled_transport() -> @httpconn.HttpConnTransport {
  @httpconn.HttpConnTransport::new()
}

///|
fn transport_with(
  max_idle~ : Int32,
  idle_timeout~ : Int32,
) -> @httpconn.HttpConnTransport {
  @httpconn.HttpConnTransport::new(
    max_idle_per_host=max_idle,
    idle_timeout_ms=idle_timeout,
  )
}

///|
/// 用指定传输发一个 GET。头、体、信号、方法都可选。
async fn send_with(
  transport : &@transport.Transport,
  port : Int32,
  headers~ : @transport.Headers = @transport.Headers::new(),
  body~ : @transport.RequestBody? = None,
  signal~ : @abort.AbortSignal? = None,
  meth~ : @transport.Method = @transport.Method::Get,
) -> @transport.RawResponse {
  transport.send({
    http_method: meth,
    url: "http://127.0.0.1:\{port}/pool",
    headers,
    body,
    timeout: Some(5000),
    proxy: None,
    on_upload_progress: None,
    signal,
  })
}

///|
/// 头块里有没有 `Connection: <value>`（测试数据都是字面量，全行精确比对，
/// 统一小写）。
fn head_has_connection(head : Array[String], value : String) -> Bool {
  let want = "connection: " + value
  let mut found = false
  for line in head {
    if line.to_lower() == want {
      found = true
    }
  }
  found
}

///|
/// 头块里有没有任何 Connection 头。
fn head_has_any_connection(head : Array[String]) -> Bool {
  let mut found = false
  for line in head {
    if line.to_lower().has_prefix("connection:") {
      found = true
    }
  }
  found
}
