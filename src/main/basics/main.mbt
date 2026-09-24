///|
/// 示例：把「请求 → 响应」链上几个不同方向各跑一遍，用 println 打印观察结果。
///
/// 覆盖状态码与状态文本、响应头、查询参数（含自定义 paramsSerializer）、
/// 二进制响应、`response_encoding` 的读法、204 空正文、4xx / 5xx 的错误分类、
/// `validate_status` 自定义校验、超时。
///
/// 除最后一段真实站点外，其余都打本程序自己起的本机 server——离线可跑、
/// 结果确定（为什么要这样混着来，见 docs/13-runnable-examples.md）。
/// 用 `moon run src/main/basics` 执行。本包只是示例，不随模块发布。
async fn main {
  @async.with_task_group() <| group => {
    let port = demo_server(group)
    let client = @moonhttp.create(
      @moonhttp.Config::default()
      .with_base_url("http://127.0.0.1:\{port}")
      .with_timeout(10_000),
    )
    println("本机 server 已就绪：http://127.0.0.1:\{port}\n")
    basic_text(client)
    query_params(client)
    custom_serializer(client)
    binary_body(client)
    encoding_reading(client)
    empty_response(client)
    error_4xx(client)
    error_5xx(client)
    custom_validate(client)
    timeout_case(client)
    real_sites()
  }
}

///|
/// 起一个按路径回不同形态响应的本机 server，返回端口。
///
/// `allow_failure=true`：某条用例中途取消/超时会让这个 handler 的写动作失败，
/// 那条失败不该把整个 server 带走——后面的用例还要用它。
async fn demo_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(allow_failure=true) <| ((request, _body, conn) => {
      let path = request.path
      let (route, query) = match path.find("?") {
        Some(index) => (path[:index], path[index + 1:])
        None => (path, "")
      }
      if route == "/hello" {
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "text/plain; charset=utf-8",
          "X-Demo": "hello",
        })
        ..write_string("你好，moonhttp")
        .end_response()
      } else if route == "/echo" {
        // 把服务端实际收到的路径与 query 回吐出来——这就是线上的样子
        let echo : Json = {
          "method": method_text(request.meth),
          "path": path,
          "query": query,
        }
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/json",
        })
        ..write_string(echo.stringify())
        .end_response()
      } else if route == "/bytes" {
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/octet-stream",
        })
        ..write(Bytes::make(1024, b'A'))
        .end_response()
      } else if route == "/empty" {
        conn..send_response(204, "No Content").end_response()
      } else if route == "/missing" {
        conn
        ..send_response(404, "Not Found", extra_headers={
          "Content-Type": "text/plain; charset=utf-8",
        })
        ..write_string("没有这个资源")
        .end_response()
      } else if route == "/boom" {
        conn
        ..send_response(500, "Internal Server Error", extra_headers={
          "Content-Type": "application/json",
        })
        ..write_string("{\"error\": \"服务端坏了\"}")
        .end_response()
      } else if route == "/teapot" {
        conn
        ..send_response(418, "I'm a teapot")
        ..write_string("短而粗")
        .end_response()
      } else if route == "/slow" {
        // 比客户端的 timeout 更慢，用来制造 ECONNABORTED
        @async.sleep(500)
        conn..send_response(200, "OK")..write_string("late").end_response()
      } else {
        conn..send_response(404, "Not Found").end_response()
      }
    })
  }
  port
}

///|
/// 把 `HttpError` 打印成几行观察结果（分类 / 描述 / 错误里带的响应）。
fn print_error(error : @moonhttp.HttpError) -> Unit {
  println("抛出错误     = \{error.code()} / \{error.message()}")
  match error.response() {
    Some(response) =>
      println(
        "错误里的响应 = \{response.status} \{response.status_text}，正文 = \{response.text()}",
      )
    None =>
      println(
        "错误里的响应 = <没有：请求没走到「收到响应」那一步>",
      )
  }
}

///|
/// 从 `/echo` 的回显里取出服务端实际收到的 query（默认参数序列化的结果）。
fn echo_query(response : @moonhttp.Response) -> String {
  let echoed = response.json() catch { _ => return response.text() }
  match echoed {
    { "query": String(query), .. } => query
    _ => response.text()
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
/// 服务端视角看到的方法名。
///
/// `@http.RequestMethod` 的 `Show` / `to_json` 实现都被标了废弃（`moon check
/// --deny-warn` 下会挂），所以这里自己映射一份，顺便打印得更像线上的样子。
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
