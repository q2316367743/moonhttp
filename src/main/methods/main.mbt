///|
/// 示例：请求方式、请求体形态与响应内容形态各来一遍，用 println 打印观察结果。
///
/// 三段分别覆盖：
/// 1. 八种请求方式（方法由 `with_method` 指定，缺省 GET）；
/// 2. 请求体四种形态（库负责序列化并补 `Content-Type`，显式设的同名头优先）；
/// 3. 响应内容形态（JSON / 纯文本 / 二进制 / 201+Location / 204 / chunked / 非法 JSON）。
///
/// 靶子是本程序自己起的 echo server，所以离线可跑、结果确定。
/// 用 `moon run src/main/methods` 执行。本包只是示例，不随模块发布。
async fn main {
  @async.with_task_group() <| group => {
    let port = echo_server(group)
    let client = @moonhttp.create(
      @moonhttp.Config::default()
      .with_base_url("http://127.0.0.1:\{port}")
      .with_timeout(10_000),
    )
    println("本机 echo server 已就绪：http://127.0.0.1:\{port}\n")
    all_methods(client)
    body_forms(client)
    response_shapes(client)
  }
}

///|
/// 起一个回显 server，返回端口。
///
/// `/echo` 把服务端实际收到的方法、路径、`Content-Type` 与请求体（截断）
/// 拼成 JSON 回给客户端——这是本示例所有「服务端看到了什么」的证据来源。
/// 其余路径提供不同形态的响应内容。
async fn echo_server(group : @async.TaskGroup[Unit]) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(allow_failure=true) <| ((request, body, conn) => {
      let path = request.path
      let (route, query) = match path.find("?") {
        Some(index) => (path[:index], path[index + 1:])
        None => (path, "")
      }
      if route == "/echo" {
        let received = body.read_all().binary()
        let echo : Json = {
          "method": method_text(request.meth),
          "path": path,
          "query": query,
          "content_type": request_header(request, "content-type"),
          "x_demo": request_header(request, "x-demo"),
          "body_len": received.length(),
          "body_preview": head_text(@utf8.decode_lossy(received), 240),
        }
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "application/json",
        })
        if request.meth is @http.Head {
          // HEAD 按 HTTP 语义只回响应头，不写正文
          conn.end_response()
        } else {
          conn..write_string(echo.stringify()).end_response()
        }
      } else if route == "/json" {
        let payload : Json = {
          "id": 7,
          "name": "moonbit",
          "tags": ["wasm", "native"],
          "nested": { "ok": true },
        }
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/json",
        })
        ..write_string(payload.stringify())
        .end_response()
      } else if route == "/text" {
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "text/plain; charset=utf-8",
        })
        ..write_string("纯文本响应，不是 JSON")
        .end_response()
      } else if route == "/bin" {
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/octet-stream",
        })
        ..write(Bytes::make(16, b'z'))
        .end_response()
      } else if route == "/created" {
        conn
        ..send_response(201, "Created", extra_headers={
          "Content-Type": "application/json",
          "Location": "/echo",
        })
        ..write_string("{\"created\": true}")
        .end_response()
      } else if route == "/empty" {
        conn..send_response(204, "No Content").end_response()
      } else if route == "/chunked" {
        // 不设 Content-Length、分多次 flush：线上就是 chunked 传输
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/plain; charset=utf-8",
        })
        let piece = "x".repeat(128 * 1024)
        for _ in 0..<8 {
          conn..write_string(piece).flush()
        }
        conn.end_response()
      } else if route == "/badjson" {
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/json",
        })
        ..write_string("{oops, 这不是 JSON}")
        .end_response()
      } else {
        conn..send_response(404, "Not Found").end_response()
      }
    })
  }
  port
}

///|
/// 服务端视角看到的方法名。
///
/// `@http.RequestMethod` 的 `Show` / `to_json` 实现都被标了废弃
/// （`moon check --deny-warn` 下会挂），所以这里自己映射一份。
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
/// 从服务端视角取一个请求头（回显给客户端当证据）。
fn request_header(request : @http.Request, name : String) -> String {
  request.headers.get(@http.CaseInsensitiveString(name)).unwrap_or("<无>")
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
/// 左侧补空格到固定宽度（标准库没有按宽度格式化的函数，输出对齐靠它）。
fn pad(text : String, width : Int) -> String {
  let buf = StringBuilder()
  buf.write_string(text)
  for _ in 0..<(width - text.length()) {
    buf.write_char(' ')
  }
  buf.to_string()
}

///|
/// 跑一次请求并把结果收成 `Result`：示例要逐条打印，不想让某一条把整段带崩。
async fn request_or_error(
  client : @moonhttp.Client,
  config : @moonhttp.Config,
) -> Result[@moonhttp.Response, @moonhttp.HttpError] {
  Ok(client.request(config)) catch {
    error => Err(error)
  }
}

///|
/// 从 `/echo` 的回显里取一个字段并渲染成一行短文本。
fn echo_field(response : @moonhttp.Response, field : String) -> String {
  let echoed = response.json() catch { _ => return "<回显不是 JSON>" }
  let found = if echoed is Object(fields) { fields.get(field) } else { None }
  match found {
    Some(String(text)) => text
    Some(value) => head_text(value.stringify(), 240)
    None => "<无此字段>"
  }
}
