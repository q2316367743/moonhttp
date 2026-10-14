// 连接复用（docs/21）示例段：连接池自 2026-10 起是缺省行为。证据取
// 服务端视角——/echo 回吐靶子真实收到的请求头：
//
// - 默认（池启用）：请求**不带** Connection 头——HTTP/1.1 持久连接是默认，
//   同一实例的后续请求复用已建立的连接、省掉重复握手（对齐 Go / Python / Node）；
// - 用户显式声明 `Connection: close`：头原样落线（set_if_absent 用户赢），
//   这条连接响应后不回池——逐请求禁复用的出口；
// - 禁池（`HttpConnTransport::new(max_idle_per_host = 0)`）：每请求一条
//   连接，线上恢复 phase 1 的 `Connection: close` 声明。

///|
async fn connection_reuse(client : @moonhttp.Client) -> Unit {
  println("== 12. 连接复用（默认开启）==")
  for _i in 1..<=3 {
    let response = client.request(@moonhttp.Config::new("/echo"))
    println(
      "复用请求   → Connection 头：\{echo_header(response, "connection")}（不带 = 1.1 默认持久，连接进池）",
    )
  }
  let explicit = client.request(
    @moonhttp.Config::new("/echo").with_header("Connection", "close"),
  )
  println(
    "显式 close → Connection 头：\{echo_header(explicit, "connection")}（用户赢，这条连接不回池）",
  )
  let unpooled = @moonhttp.Client::new(
    config=@moonhttp.Config::default()
      .with_base_url(target_base)
      .with_timeout(10_000),
    transport=@moonhttp.HttpConnTransport::new(max_idle_per_host=0),
  )
  let disabled = unpooled.request(@moonhttp.Config::new("/echo"))
  println(
    "禁池       → Connection 头：\{echo_header(disabled, "connection")}（phase 1 老口径）",
  )
  println("")
}
