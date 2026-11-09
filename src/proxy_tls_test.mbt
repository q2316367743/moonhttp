// HTTPS 代理（`ProxyProtocol::Https`）的线上时序用例：先与代理做 TLS，
// 再在这层 TLS 里发 CONNECT。配置形状与凭据规则在 `src/proxy_test.mbt`，
// 隧道本身的行为也在那里；这里只钉「TLS 在 CONNECT 之前」这一条。

///|
/// `protocol=Https` 的代理：**先与代理做 TLS**，再在其上发 CONNECT。
///
/// 这条用例不要求本机有一个能完成握手的 TLS 代理（那要证书），只钉住
/// 「线上第一段字节是 TLS 握手记录」——裸 TCP 代理收到的第一段会是
/// 明文 `CONNECT ...`。这正是修掉的那个缺陷：旧实现不看代理地址的
/// `https://`，CONNECT 与 `Proxy-Authorization` 全部明文过网，真正的 TLS
/// 代理也连不上。TLS 握手本身失败是预期结果（对端不会说 TLS），
/// 分类应是网络失败。
async test "an https proxy is reached through tls before connect" {
  let proxy = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let proxy_port = proxy.addr.port()
  let seen : Array[Bytes] = []
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      proxy.run_forever() <| ((conn, _addr) => {
        // 只收第一段：TLS ClientHello 的开头足够区分「握手」与「明文 CONNECT」
        match conn.read_some() {
          Some(bytes) => seen.push(bytes)
          None => ()
        }
      })
    }
    let error = try {
      ignore(
        @moonhttp.Client::new().request(
          @moonhttp.Config::new("http://127.0.0.1:1/").with_proxy(
            "127.0.0.1",
            port=proxy_port,
            protocol=@moonhttp.ProxyProtocol::Https,
            username="u",
            password="p",
          ),
        ),
      )
      None
    } catch {
      error => Some(error)
    }
    // 伪代理不会回 TLS 握手；失败应归网络层，而不是「协议不支持」
    assert_eq(error.unwrap().code(), @moonhttp.ErrorCode::Network)
  }
  assert_eq(seen.length(), 1)
  let first = seen[0]
  // TLS 记录层：ContentType=handshake(0x16) + 主版本 0x03
  assert_true(first.length() >= 2)
  assert_eq(first[0], b'\x16')
  assert_eq(first[1], b'\x03')
  // CONNECT 与代理凭据都必须在 TLS 里面，不能以明文出现在线上
  let wire_text = @utf8.decode_lossy(first)
  assert_false(wire_text.contains("CONNECT"))
  assert_false(wire_text.contains("Proxy-Authorization"))
  assert_false(wire_text.contains("Basic "))
}
