// 各条用例：每条一个函数，由 `main.mbt` 的 `main` 依次调用。
// 靶子是本机 server（见 `main.mbt` 的 `redirect_server`）与两个真实站点。

///|
/// 1. 默认跟随：`/hop/2` 连跳两级，交出去的是终点响应。
async fn follow_chain(client : @moonhttp.Client) -> Unit {
  println("== 1. 默认跟随（max_redirects 默认 5，这里跳两级）==")
  show("GET /hop/2", client, @moonhttp.Config::new("/hop/2"))
  println("")
}

///|
/// 2. `max_redirects(0)`：完全不跟随，3xx 原样交给调用方。
///
/// 注意 3xx 不在默认的「2xx 才算成功」里，所以这时会抛错——错误里带着那个 3xx
/// 响应，`Location` 照样拿得到（要让它不抛，配 `validate_status` 即可）。
async fn no_follow(client : @moonhttp.Client) -> Unit {
  println("== 2. max_redirects(0)：不跟随，3xx 原样返回 ==")
  show(
    "GET /hop/1（0 跳）",
    client,
    @moonhttp.Config::new("/hop/1").with_max_redirects(0),
  )
  println("")
}

///|
/// 3. 超过上限：默认 5 跳，`/hop/6` 需要 6 跳 → `ERR_FR_TOO_MANY_REDIRECTS`。
async fn over_limit(client : @moonhttp.Client) -> Unit {
  println("== 3. 超过上限（默认 5 跳）==")
  show("GET /hop/6", client, @moonhttp.Config::new("/hop/6"))
  println("")
}

///|
/// 4. 301 / 302 对 POST 的降级：方法变成 GET，正文与 `content-*` 一并丢掉。
async fn post_downgrade(client : @moonhttp.Client) -> Unit {
  println("== 4. 301 / 302 遇上 POST：降级成 GET（正文丢掉）==")
  for code in [301, 302] {
    show(
      "POST /to/\{code}",
      client,
      @moonhttp.Config::new("/to/\{code}")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_json({ "payload": "should be dropped" }),
    )
  }
  println("")
}

///|
/// 5. 303 See Other：非 GET/HEAD 一律变 GET（PUT 也不例外）。
async fn see_other(client : @moonhttp.Client) -> Unit {
  println("== 5. 303 遇上 PUT：也变 GET ==")
  show(
    "PUT /to/303",
    client,
    @moonhttp.Config::new("/to/303")
    .with_method(@moonhttp.Method::Put)
    .with_data_from_json({ "payload": "dropped too" }),
  )
  println("")
}

///|
/// 6. 307 / 308：方法与正文原样带到下一跳（重发同一份请求）。
async fn method_preserved(client : @moonhttp.Client) -> Unit {
  println("== 6. 307 / 308：方法与正文都保持 ==")
  for code in [307, 308] {
    show(
      "POST /to/\{code}",
      client,
      @moonhttp.Config::new("/to/\{code}")
      .with_method(@moonhttp.Method::Post)
      .with_data_from_json({ "payload": "kept" }),
    )
  }
  println("")
}

///|
/// 7. 成环：跳到自己身上，靠 `max_redirects` 兜底（不会无限转下去）。
async fn redirect_loop(client : @moonhttp.Client) -> Unit {
  println("== 7. 成环（/loop → /loop）==")
  show("GET /loop", client, @moonhttp.Config::new("/loop"))
  println("")
}

///|
/// 8. 跨 host 丢凭据：`127.0.0.1` → `localhost` 是两个不同的 host 字符串，
/// 库会在这一跳上把 `Authorization` 丢掉（跳转可能被引到别的主机上去）。
///
/// `localhost` 在有些系统上先解析到 IPv6（::1），而本机 server 只监听 IPv4——
/// 这条要是连不上，就是环境问题而不是库的行为，输出里会如实打印错误。
async fn credential_dropped(client : @moonhttp.Client) -> Unit {
  println("== 8. 跨 host 丢 Authorization（127.0.0.1 → localhost）==")
  show(
    "GET /cross-host",
    client,
    @moonhttp.Config::new("/cross-host").with_header(
      "Authorization", "Bearer secret-token",
    ),
  )
  println(
    "  （同 host 的跳转不会丢：把上面的 Authorization 拿去打 /to/302 就能看到它还在）",
  )
  show(
    "GET /to/302（同 host）",
    client,
    @moonhttp.Config::new("/to/302").with_header(
      "Authorization", "Bearer secret-token",
    ),
  )
  println("")
}

///|
/// 9. 真实站点：两个国内直连可达的跳转（302 与 301 各一），打印最终地址。
async fn real_sites() -> Unit {
  println("== 9. 真实站点（国内直连可达）==")
  let client = @moonhttp.create(
    @moonhttp.Config::default().with_timeout(20_000),
  )
  show(
    "http://www.qq.com/",
    client,
    @moonhttp.Config::new("http://www.qq.com/"),
  )
  show(
    "http://mirrors.tuna.tsinghua.edu.cn/",
    client,
    @moonhttp.Config::new("http://mirrors.tuna.tsinghua.edu.cn/"),
  )
  println("")
}

///|
/// 取字符串的前 `limit` 个字符（不足就整体返回）。
///
/// 真实站点那两条的正文是整页 HTML，打印前得截断，不然控制台会被淹掉。
fn head_text(text : String, limit : Int) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned() + "…"
  }
}

///|
/// 左侧补空格到固定宽度（输出对齐用）。
fn pad(text : String, width : Int) -> String {
  let buf = StringBuilder()
  buf.write_string(text)
  for _ in 0..<(width - text.length()) {
    buf.write_char(' ')
  }
  buf.to_string()
}
