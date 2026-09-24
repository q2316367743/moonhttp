///|
/// 示例：代理。
///
/// 需要本机有一个 HTTP 代理在 `PROXY_URL` 指的地方（默认 `http://127.0.0.1:7890`），
/// 并且能联网——示例里的目标是 GitHub 与 ipify；对照组（直连）打的是华为云镜像。
///
/// 五段：拆代理地址、直连对照、走代理、出口 IP 对比、两条失败路径。
/// 所有外网请求都收在 try / catch 里：代理没起或断网时打印错误分类，不 panic。
/// 用 `moon run src/main/proxy` 执行。本包只是示例，不随模块发布。
let proxy_url : String = "http://127.0.0.1:7890"

///|
/// 演示用的出口 IP 查询（走不走代理，这个地址看到的出口不一样）。
let echo_ip_url : String = "https://ifconfig.me/ip"

///|
async fn main {
  println("== 0. 把代理 URL 拆成库要的 host / port ==")
  let (proxy_host, proxy_port, proxy_protocol) = parse_proxy_url(proxy_url)
  let protocol_text = match proxy_protocol {
    @moonhttp.ProxyProtocol::Http => "http"
    @moonhttp.ProxyProtocol::Https => "https"
  }
  println("配置项 = \{proxy_url}")
  println(
    "拆出来 = host=\{proxy_host} port=\{proxy_port} protocol=\{protocol_text}",
  )
  println(
    "（`with_proxy` 收的是分开的 host / port / protocol，与 axios 的 proxy 配置对象同形，",
  )
  println(" 不是一整条 URL——所以这一刀得调用方自己切）\n")
  let direct = @moonhttp.create(
    @moonhttp.Config::default().with_timeout(15_000),
  )
  println("== 1. 直连对照（不经代理，打华为云镜像）==")
  show(
    "直连",
    direct,
    @moonhttp.Config::new(
      "https://mirrors.huaweicloud.com/openjdk/27/openjdk-27_macos-aarch64_bin.tar.gz.sha256",
    ),
  )
  println("")
  println(
    "== 2. 走代理（打 GitHub，直连不一定通、走代理才有）==",
  )
  let via_proxy = @moonhttp.Config::new("https://api.github.com/zen").with_proxy(
    proxy_host,
    port=proxy_port,
    protocol=proxy_protocol,
  )
  show("走代理", direct, via_proxy)
  println("")
  println(
    "== 3. 出口 IP 对比（同一台机器，两条路的出口不一样）==",
  )
  show("直连出口", direct, @moonhttp.Config::new(echo_ip_url))
  show(
    "代理出口",
    direct,
    @moonhttp.Config::new(echo_ip_url).with_proxy(
      proxy_host,
      port=proxy_port,
      protocol=proxy_protocol,
    ),
  )
  println("")
  println("== 4. 失败路径：代理端口上没人监听 ==")
  show(
    "端口没人",
    direct,
    @moonhttp.Config::new("https://api.github.com/zen").with_proxy(
      proxy_host,
      port=1,
    ),
  )
  println(
    "（分类是 ERR_NETWORK 而不是超时/取消：连不上代理，一个字都没发出去）\n",
  )
  println("== 5. 失败路径：配了代理但没给 host ==")
  show(
    "缺 host",
    direct,
    @moonhttp.Config::new("https://api.github.com/zen").with_proxy(""),
  )
  println(
    "（缺 host 是配置错误 ERR_INVALID_URL，而不是悄悄退回直连）\n",
  )
}

///|
/// 把 `http://host:port` 拆成 `with_proxy` 要的三段。
///
/// 端口用 `try!`：这里的输入是常量，写错了应该当场炸掉，
/// 而不是静默地拨一个错误的端口。
fn parse_proxy_url(url : String) -> (String, Int, @moonhttp.ProxyProtocol) {
  let protocol = if url.has_prefix("https://") {
    @moonhttp.ProxyProtocol::Https
  } else {
    @moonhttp.ProxyProtocol::Http
  }
  let rest = match url.find("://") {
    Some(index) => url[index + 3:]
    None => url
  }
  match rest.find(":") {
    Some(index) =>
      (
        rest[:index].to_owned(),
        try! @string.parse_int(rest[index + 1:]),
        protocol,
      )
    None => (rest.to_owned(), 80, protocol)
  }
}

///|
/// 打一次请求并打印结果，失败时打印错误分类。
///
/// 外网请求一律走这个收口：代理没起、断网、站点 5xx 都只是打印一行，
/// 后面的段落照常往下跑。
async fn show(
  label : String,
  client : @moonhttp.Client,
  config : @moonhttp.Config,
) -> Unit {
  try {
    let response = client.request(config)
    println(
      "\{pad(label, 8)} → \{response.status} \{response.status_text}，正文 = \{head_text(response.text().trim().to_owned(), 90)}",
    )
  } catch {
    error =>
      println(
        "\{pad(label, 8)} → 抛出 \{error.code()}：\{error.message()}",
      )
  }
}

///|
/// 取字符串的前 `limit` 个字符（不足就整体返回），避免示例因越界 panic。
fn head_text(text : String, limit : Int) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned()
  }
}

///|
/// 左侧补空格到固定宽度（输出对齐用；标准库没有按宽度格式化的函数）。
fn pad(text : String, width : Int) -> String {
  let buf = StringBuilder()
  buf.write_string(text)
  for _ in 0..<(width - text.length()) {
    buf.write_char(' ')
  }
  buf.to_string()
}
