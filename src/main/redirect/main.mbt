///|
/// 示例：自动重定向。
///
/// 库的策略只有一个旋钮 `max_redirects`（默认 5，`<= 0` 完全不跟随），
/// 逐跳的改写规则（方法、正文、`content-*`、凭据、`Host`）内置。
/// 这里把这些规则逐条跑一遍：
///
/// 1. 默认跟随（连跳两级）；2. `max_redirects(0)` 不跟随；3. 超过上限报错；
/// 4. 301/302 对 POST 降级成 GET；5. 303 对非 GET/HEAD 也降级成 GET；
/// 6. 307/308 保持方法与正文；7. 成环；8. 跨 host 丢 `Authorization`；
/// 9. 真实站点（qq.com 的 302、清华镜像的 301）。
///
/// 用 `moon run src/main/redirect` 执行。本包只是示例，不随模块发布。
async fn main {
  @async.with_task_group() <| group => {
    let port = redirect_server(group)
    let client = @moonhttp.create(
      @moonhttp.Config::default()
      .with_base_url("http://127.0.0.1:\{port}")
      .with_timeout(10_000),
    )
    println("本机 server 已就绪：http://127.0.0.1:\{port}\n")
    follow_chain(client)
    no_follow(client)
    over_limit(client)
    post_downgrade(client)
    see_other(client)
    method_preserved(client)
    redirect_loop(client)
    credential_dropped(client)
    real_sites()
  }
}

///|
/// 起一个「按路径决定怎么跳」的本机 server，返回端口。
///
/// `/hop/{n}` 连跳 n 级后到终点；`/to/{code}` 用指定状态码跳到 `/final`；
/// `/loop` 自己指自己；`/cross-host` 跳到 `localhost`（与 `127.0.0.1` 是不同的
/// host 字符串，用来验证跨 host 时 `Authorization` 会不会被丢掉）。
/// 所有跳转都以 `/final` 收尾，它回显服务端实际收到的方法与正文长度。
async fn redirect_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(allow_failure=true) <| ((request, body, conn) => {
      let path = request.path
      let received = body.read_all().binary()
      if path.has_prefix("/hop/") {
        let depth = try! @string.parse_int(path[5:])
        if depth > 0 {
          redirect_to(conn, 302, "/hop/\{depth - 1}")
        } else {
          final_response(conn, request, received.length())
        }
      } else if path.has_prefix("/to/") {
        let code = try! @string.parse_int(path[4:])
        redirect_to(conn, code, "/final")
      } else if path == "/loop" {
        redirect_to(conn, 302, "/loop")
      } else if path == "/cross-host" {
        // 换成另一个 host 字符串（localhost），库应当把 Authorization 丢掉
        redirect_to(conn, 302, "http://localhost:\{port}/final")
      } else if path == "/final" {
        final_response(conn, request, received.length())
      } else {
        conn
        ..send_response(404, "Not Found")
        ..write_string("没有这个路径：\{path}")
        .end_response()
      }
    })
  }
  port
}

///|
/// 回一个 3xx + `Location`（重定向的两种必备条件，缺一个就跟随不了）。
async fn redirect_to(
  conn : @http.ServerConnection,
  code : Int,
  location : String,
) -> Unit {
  conn
  ..send_response(code, "Redirect", extra_headers={ "Location": location })
  .end_response()
}

///|
/// 跳转的终点：把「服务端实际收到的方法、正文长度、Authorization 头」回显出来。
///
/// 这三样正是判断重定向是否改写了请求的证据。
async fn final_response(
  conn : @http.ServerConnection,
  request : @http.Request,
  body_len : Int,
) -> Unit {
  let auth = match
    request.headers.get(@http.CaseInsensitiveString("authorization")) {
    Some(value) => value
    None => "<没带>"
  }
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "text/plain; charset=utf-8",
  })
  ..write_string(
    "终点收到：方法 = \{method_text(request.meth)}，正文 \{body_len} 字节，Authorization = \{auth}",
  )
  .end_response()
}

///|
/// 服务端视角看到的方法名（`@http.RequestMethod` 的 `Show` 已废弃，自己映射）。
fn method_text(meth : @http.RequestMethod) -> String {
  match meth {
    @http.Get => "GET"
    @http.Head => "HEAD"
    @http.Post => "POST"
    @http.Put => "PUT"
    @http.Delete => "DELETE"
    @http.Connect => "CONNECT"
    @http.Options => "OPTIONS"
    @http.Trace => "TRACE"
    @http.Patch => "PATCH"
  }
}

///|
/// 打一次请求并打印一行结果：正常时给「状态 + 正文 + 最终地址」，否则给错误分类。
///
/// `response.config.url` 是**产出这份响应**的那一跳的地址，所以它能证明「跟到了哪」。
async fn show(
  label : String,
  client : @moonhttp.Client,
  config : @moonhttp.Config,
) -> Unit {
  try {
    let response = client.request(config)
    let final_url = response.config.url.unwrap_or("<未知>")
    println(
      "\{pad(label, 22)} → \{response.status}，最终地址 = \{final_url}",
    )
    println(
      "\{pad("", 22)}   正文（截断）= \{head_text(response.text(), 100)}",
    )
  } catch {
    error =>
      match error.response() {
        Some(response) =>
          println(
            "\{pad(label, 22)} → 抛出 \{error.code()}，错误里带的响应 = \{response.status} \{response.status_text}，Location = \{response.headers.get("location").unwrap_or("<无>")}",
          )
        None =>
          println(
            "\{pad(label, 22)} → 抛出 \{error.code()}：\{error.message()}",
          )
      }
  }
}
