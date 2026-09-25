///|
/// 示例：拦截器（`Interceptors`）。
///
/// 四条链的形状与 axios 大体一致（**错误按来源分流**是本项目的差异）：
/// - 请求侧 `Config -> Config`，**后注册先跑（LIFO）**，用来补头、补参数、拦下请求；
/// - 请求侧错误处理器 `HttpError -> Response`，**后注册先跑（LIFO）**，接住被拦下、
///   连不上、超时、取消、重定向超限——网络类重试的落点；
/// - 响应侧 `Response -> Response`，**先注册先跑（FIFO）**，用来观察、改写；
/// - 响应侧错误处理器，接住**只有**状态码没通过校验（默认非 2xx）的失败，
///   降级与按状态码重试的落点。
///
/// 五段：
/// 1. 请求拦截器补 `Authorization: token`（echo server 回显收到的头当证据）；
/// 2. 注册顺序：请求侧 LIFO、响应侧 FIFO；
/// 3. 响应拦截器改写响应体 JSON（`with_json`）与响应头（`with_headers`）；
/// 4. 请求拦截器抛错中止请求，**请求侧**错误处理器接住并救回；
/// 5. 覆盖范围：`stream` 只走请求侧链（两个错误处理器与响应侧都只在 `Client::request` 上）。
///
/// 用 `moon run src/main/interceptors` 执行。本包只是示例，不随模块发布。
async fn main {
  @async.with_task_group() <| group => {
    let port = echo_server(group)
    let base = "http://127.0.0.1:\{port}"
    println("本机 echo server 已就绪：\{base}\n")
    inject_token(base)
    chain_order(base)
    rewrite_response(base)
    abort_and_rescue(base)
    stream_scope(base)
  }
}

///|
/// 起一个回显 server：把收到的 `Authorization`、自定义头与路径拼成 JSON 回给客户端。
async fn echo_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(allow_failure=true) <| ((request, body, conn) => {
      let _ = body.read_all().binary()
      let echo : Json = {
        "path": request.path,
        "authorization": request_header(request, "authorization"),
        "x_demo": request_header(request, "x-demo"),
        "x_trace": request_header(request, "x-trace"),
      }
      if request.path.has_prefix("/json") {
        let payload : Json = {
          "code": 0,
          "data": "服务端原文",
          "items": [1, 2, 3],
        }
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/json",
          "X-From": "服务端",
        })
        ..write_string(payload.stringify())
        .end_response()
      } else {
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/json",
        })
        ..write_string(echo.stringify())
        .end_response()
      }
    })
  }
  port
}

///|
/// 从服务端视角取一个请求头（缺了给占位符），回显给客户端当证据。
fn request_header(request : @http.Request, name : String) -> String {
  request.headers.get(@http.CaseInsensitiveString(name)).unwrap_or("<没带>")
}

///|
/// 取字符串的前 `limit` 个字符（不足就整体返回）。
fn head_text(text : String, limit : Int) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned() + "…"
  }
}

///|
/// 从回显里取一个字段（取不到就返回原文，便于排查）。
fn echo_field(response : @moonhttp.Response, field : String) -> String {
  let echoed = response.json() catch { _ => return response.text() }
  let found = if echoed is Object(fields) { fields.get(field) } else { None }
  match found {
    Some(String(text)) => text
    Some(value) => value.stringify()
    None => "<无此字段>"
  }
}

///|
/// 1. 请求拦截器补 token：请求发出前统一挂 `Authorization`，
/// 业务代码里就不必每次写（echo server 回显收到的头，证明它真的发出去了）。
///
/// 这段用的是「token 放在一个地方、拦截器去取」的写法：把 token 换成从内存、
/// 从文件、从刷新逻辑里取，形状都一样。
async fn inject_token(base : String) -> Unit {
  println("== 1. 请求拦截器补 Authorization（token 注入）==")
  let token_store : Array[String] = ["demo-token-12345"]
  let client = @moonhttp.Client::new(
    config=@moonhttp.Config::default().with_base_url(base),
    interceptors=@moonhttp.Interceptors::new().use_request(config => {
      match token_store[0] {
        "" => config
        token => {
          // 调用方自己给了就不动它（axios 里 `if (!config.headers.Authorization)`
          // 的等价写法）。拦截器跑在配置合并之后，直接 with_header 会**覆盖**
          // 调用方显式设的那个头——那通常不是想要的。
          let existing = config.headers
            .unwrap_or(@moonhttp.Headers::new())
            .get("Authorization")
          match existing {
            Some(_) => config
            None => config.with_header("Authorization", "Bearer \{token}")
          }
        }
      }
    }),
  )
  let response = client.request(@moonhttp.Config::new("/whoami"))
  println(
    "服务端收到的 Authorization = \{echo_field(response, "authorization")}",
  )
  let explicit = client.request(
    @moonhttp.Config::new("/whoami").with_header(
      "Authorization", "Bearer override",
    ),
  )
  println(
    "调用方显式给了之后 = \{echo_field(explicit, "authorization")}（拦截器让位）\n",
  )
}

///|
/// 2. 注册顺序：请求侧后注册的先跑（LIFO），响应侧先注册的先跑（FIFO）。
///
/// 与 axios 的 `requestInterceptors.unshift` / `responseInterceptors.push` 对齐，
/// 所以「最后注册的请求拦截器最先看到配置」。
async fn chain_order(base : String) -> Unit {
  println("== 2. 链的顺序（请求 LIFO、响应 FIFO）==")
  let client = @moonhttp.Client::new(
    config=@moonhttp.Config::default().with_base_url(base),
    interceptors=@moonhttp.Interceptors::new()
      // 请求侧：先注册 A、再注册 B —— 执行顺序应该是 B → A
      .use_request(config => {
        println(
          "  [请求 A] 看到 X-Trace = \{config.headers.unwrap_or(@moonhttp.Headers::new()).get("X-Trace").unwrap_or("<没带>")}",
        )
        config.with_header("X-Trace", "A")
      })
      .use_request(config => {
        println("  [请求 B] 先跑（后注册先跑）")
        config.with_header("X-Trace", "B")
      })
      // 响应侧：先注册 1、再注册 2 —— 执行顺序应该是 1 → 2
      .use_response(response => {
        println("  [响应 1] 先跑（先注册先跑）")
        response
      })
      .use_response(response => {
        println("  [响应 2] 后跑")
        response
      }),
  )
  let response = client.request(@moonhttp.Config::new("/whoami"))
  println(
    "服务端最终收到的 X-Trace = \{echo_field(response, "x_trace")}（A 覆盖了 B）\n",
  )
}

///|
/// 3. 响应拦截器改写响应体与响应头。
///
/// 解析走 `json()`（它抛 `@json.ParseError`，拦截器签名只收 `HttpError`，
/// 所以要用 `try ... catch` 收掉），写回走 `with_json` / `with_headers`。
/// 这是 axios 里 `transformResponse` 最常干的事。
async fn rewrite_response(base : String) -> Unit {
  println("== 3. 响应拦截器改写响应体与响应头 ==")
  let client = @moonhttp.Client::new(
    config=@moonhttp.Config::default().with_base_url(base),
    interceptors=@moonhttp.Interceptors::new().use_response(response => {
      let parsed : Json? = Some(response.json()) catch { _ => None }
      match parsed {
        Some({ "data": String(data), "code": Number(code, ..), .. }) =>
          response
          .with_json({
            "code": code.to_int(),
            "data": data,
            "wrapped_by": "响应拦截器",
            "note": "原始响应体已被替换",
          })
          .with_headers(
            response.headers.set("X-Intercepted", "yes").set("X-Server", "no"),
          )
        _ => response
      }
    }),
  )
  let response = client.request(@moonhttp.Config::new("/json"))
  println(
    "改写过后的响应头 = X-Intercepted: \{response.headers.get("x-intercepted").unwrap_or("<无>")}",
  )
  println(
    "服务端原来给的头 = X-From: \{response.headers.get("x-from").unwrap_or("<无>")}",
  )
  println("改写过后的正文 = \{response.text()}")
  println("（`Response::with_*` 返回新响应，不改原对象）\n")
}

///|
/// 4. 请求拦截器抛错中止请求，由**请求侧**错误处理器接住并救回。
///
/// 错误按来源分流：被拦下、连不上、超时、取消、重定向超限都归**请求侧**错误处理器
/// （理由见 docs/11-interceptors.md），响应侧错误处理器只在「请求成功、但状态码不是
/// 2xx」时被调用。这里演示最实用的那条——**返回之前存下来的响应**：拦截器发现请求里
/// 没有 `X-Api-Key` 就拦下，错误处理器把上一次成功拿到的响应还回去，调用方看到的是成功。
/// （本项目造不出一个全新的 `Response`，救回只能用存下来的、或错误里那份。）
async fn abort_and_rescue(base : String) -> Unit {
  println(
    "== 4. 请求拦截器中止请求 + 请求侧错误处理器救回 ==",
  )
  let request_rejects : Array[String] = []
  let response_rejects : Array[String] = []
  let mut cached : @moonhttp.Response? = None
  let client = @moonhttp.Client::new(
    config=@moonhttp.Config::default().with_base_url(base),
    interceptors=@moonhttp.Interceptors::new()
      .use_request(
        config => {
          let key = config.headers
            .unwrap_or(@moonhttp.Headers::new())
            .get("X-Api-Key")
          match key {
            Some(_) => config
            None =>
              raise @moonhttp.HttpError::new(
                "缺少 X-Api-Key，拦下这次请求",
                @moonhttp.ErrorCode::BadRequest,
                config,
              )
          }
        },
        on_rejected=error => {
          request_rejects.push(error.message())
          println(
            "  [请求侧 on_rejected] 收到：\{error.code()} / \{error.message()}",
          )
          match cached {
            Some(response) => {
              println(
                "  返回上一次存下的响应（这次请求根本没发出去）",
              )
              response
            }
            None => raise error
          }
        },
      )
      .use_response(response => response, on_rejected=error => {
        response_rejects.push(error.message())
        println(
          "  [响应侧 on_rejected] 收到：\{error.code()} / \{error.message()}",
        )
        raise error
      }),
  )
  // 第一次不带 X-Api-Key：被拦下，缓存还是空的，救不回来，错误原样抛给调用方
  let _ = try {
    ignore(client.request(@moonhttp.Config::new("/whoami")))
    println("没抛错（不应该）")
  } catch {
    error => println("调用方拿到：\{error.code()} / \{error.message()}")
  }
  // 带上 X-Api-Key：拦下的条件不成立，正常发出去，把响应存下来当「缓存」
  let ok = client.request(
    @moonhttp.Config::new("/whoami").with_header("X-Api-Key", "k-1"),
  )
  cached = Some(ok)
  println(
    "带上 X-Api-Key 之后 = \{ok.status}（拦下的条件不成立就放行）",
  )
  // 再不带：这次被拦下，但错误处理器手里有缓存，救回成一个成功响应
  let rescued = client.request(@moonhttp.Config::new("/whoami"))
  println(
    "第二次不带 key = \{rescued.status}（被拦下后由请求侧错误处理器救回）",
  )
  println(
    "两侧 on_rejected 次数 = \{request_rejects.length()} / \{response_rejects.length()}（后者是 0：状态码没失败，响应侧不该被调用）\n",
  )
}

///|
/// 5. 覆盖范围：`stream` / `sse` 只过**请求拦截器**——两个错误处理器与响应侧都只在
/// `Client::request` 上，因为它们的落点都是一份 `Response`（读全量之后的形状），
/// 而流式入口把响应体留给调用方自己读（见 docs/11-interceptors.md）。
async fn stream_scope(base : String) -> Unit {
  println("== 5. 覆盖范围：stream 只走请求侧链 ==")
  let client = @moonhttp.Client::new(
    config=@moonhttp.Config::default().with_base_url(base),
    interceptors=@moonhttp.Interceptors::new()
      .use_request(config => {
        println("  [请求拦截器] 跑了")
        config.with_header("X-Demo", "stream")
      })
      .use_response(response => {
        println("  [响应拦截器] 跑了（stream 上不该出现这行）")
        response
      }),
  )
  let stream = client.stream(@moonhttp.Config::new("/whoami"))
  let body = stream.read_all()
  println(
    "流式读到的正文 = \{head_text(@utf8.decode_lossy(body), 120)}（请求侧的头照样发了）",
  )
  println("")
}
