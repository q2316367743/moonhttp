// 三段用例：请求方式、请求体形态、响应内容形态。
// 靶子是本机 echo server（见 `main.mbt` 的 `echo_server`）。

///|
/// 1. 八种请求方式：方法由 `with_method` 指定（`Config` 缺省是 GET），
/// 服务端把「它实际收到的方法」回显出来。
async fn all_methods(client : @moonhttp.Client) -> Unit {
  println(
    "== 1. 不同请求方式（服务端回显实际收到的方法）==",
  )
  let methods : Array[(@moonhttp.Method, String, Bool)] = [
    (@moonhttp.Method::Get, "GET", false),
    (@moonhttp.Method::Head, "HEAD", false),
    (@moonhttp.Method::Post, "POST", true),
    (@moonhttp.Method::Put, "PUT", true),
    (@moonhttp.Method::Patch, "PATCH", true),
    (@moonhttp.Method::Delete, "DELETE", true),
    (@moonhttp.Method::Options, "OPTIONS", false),
    (@moonhttp.Method::Trace, "TRACE", false),
  ]
  for entry in methods {
    let (verb, label, with_body) = entry
    let config = @moonhttp.Config::new("/echo").with_method(verb)
    let config = if with_body {
      config.with_data_from_json({ "sent_by": label })
    } else {
      config
    }
    match request_or_error(client, config) {
      Ok(response) =>
        if verb is @moonhttp.Method::Head {
          println(
            "\{pad(label, 8)} → 状态 \{response.status}，正文 \{response.bytes().length()} 字节（HEAD 按语义只回头）",
          )
        } else {
          println(
            "\{pad(label, 8)} → 状态 \{response.status}，服务端回显方法 = \{echo_field(response, "method")}",
          )
        }
      Err(error) =>
        println(
          "\{pad(label, 8)} → 抛出 \{error.code()}：\{error.message()}",
        )
    }
  }
  println("")
}

///|
/// 2. 请求体四种形态：库负责序列化并补 `Content-Type`，
/// 而调用方显式设置的同名头永远优先（第一条就是）。
async fn body_forms(client : @moonhttp.Client) -> Unit {
  println("== 2. 请求体四种形态（都是 POST /echo）==")
  show_echo(
    client,
    "raw str",
    @moonhttp.Config::new("/echo")
    .with_method(@moonhttp.Method::Post)
    .with_data_from_str("user=alice&password=s3cret")
    .with_header("Content-Type", "application/x-www-form-urlencoded"),
  )
  show_echo(
    client,
    "json",
    @moonhttp.Config::new("/echo")
    .with_method(@moonhttp.Method::Post)
    .with_data_from_json({ "name": "moonbit", "star": 42 }),
  )
  show_echo(
    client,
    "urlencod",
    @moonhttp.Config::new("/echo")
    .with_method(@moonhttp.Method::Post)
    .with_data_from_urlencoded({ "a": 1, "tags": ["x", "y"] }),
  )
  show_echo(
    client,
    "multipart",
    @moonhttp.Config::new("/echo")
    .with_method(@moonhttp.Method::Post)
    .with_data_from_form(
      @moonhttp.FormData::new()
      .append_text("field", "文本字段")
      .append_file(
        "file",
        "hello.txt",
        b"file-content",
        content_type="text/plain",
      ),
    ),
  )
  println(
    "（`with_data_from_str` 不推断类型，头要自己设；另外三种会自动补，见上面的 Content-Type）",
  )
  println("")
}

///|
/// 发一次带 body 的请求，打印服务端回显的 `Content-Type`、长度与正文（截断）。
async fn show_echo(
  client : @moonhttp.Client,
  label : String,
  config : @moonhttp.Config,
) -> Unit {
  match request_or_error(client, config) {
    Ok(response) => {
      println(
        "[\{pad(label, 9)}] Content-Type = \{echo_field(response, "content_type")}",
      )
      println(
        "            长度 \{echo_field(response, "body_len")} 字节，正文 = \{echo_field(response, "body_preview")}",
      )
    }
    Err(error) =>
      println("[\{pad(label, 9)}] 抛出 \{error.code()}：\{error.message()}")
  }
}

///|
/// 3. 不同响应内容：读法由调用方按内容类型自己选（库不做任何猜测）。
async fn response_shapes(client : @moonhttp.Client) -> Unit {
  println("== 3. 不同响应内容 ==")
  // (1) JSON：要对象就显式解析
  let json_response = client.request(@moonhttp.Config::new("/json"))
  match (try! json_response.json()) {
    { "id": Number(id, ..), "name": String(name), "tags": Array(tags), .. } => {
      let names = StringBuilder()
      for tag in tags {
        match tag {
          String(text) => names.write_string(text + " ")
          _ => ()
        }
      }
      println(
        "[json]      id=\{id.to_int()} name=\{name} tags=\{names.to_string().trim()}",
      )
    }
    _ => println("[json]      响应不符合预期：\{json_response.text()}")
  }
  // (2) 纯文本：它认得出来不是 JSON——解析这一步是显式的，失败会抛错
  let text_response = client.request(@moonhttp.Config::new("/text"))
  println("[text]      text() = \{text_response.text()}")
  try {
    ignore(text_response.json())
    println("[text]      json() 没抛错（不应该）")
  } catch {
    _ =>
      println(
        "[text]      json() 按预期抛出解析错误（正文不是 JSON）",
      )
  }
  // (3) 二进制：只有 bytes() 是精确的
  let bin_response = client.request(@moonhttp.Config::new("/bin"))
  let bin = bin_response.bytes()
  println(
    "[bin]       \{bin.length()} 字节，首字节 = \{bin[0].to_int()}（'z' = 122）",
  )
  // (4) 201 Created：2xx 里不止 200，Location 头照常能读
  let created = client.request(
    @moonhttp.Config::new("/created").with_method(@moonhttp.Method::Post),
  )
  println(
    "[created]   \{created.status} \{created.status_text}，Location = \{created.headers.get("location").unwrap_or("<无>")}",
  )
  // (5) 204：没有正文的响应
  let empty = client.request(@moonhttp.Config::new("/empty"))
  println(
    "[empty]     \{empty.status} \{empty.status_text}，正文 \{empty.bytes().length()} 字节",
  )
  // (6) 分块吐出的正文：服务端分 8 次 flush，库会一直读到 EOF 才收口，
  //     所以长度对不对不取决于服务端有没有给 Content-Length
  let chunked = client.request(@moonhttp.Config::new("/chunked"))
  println(
    "[chunked]   transfer-encoding = \{chunked.headers.get("transfer-encoding").unwrap_or("<无>")}，content-length = \{chunked.headers.get("content-length").unwrap_or("<无>")}",
  )
  println(
    "[chunked]   content_length() = \{chunked.content_length()}，text().length() = \{chunked.text().length()}",
  )
  // (7) 非法 JSON：库只负责给字节，解析是调用方的事，错了就是解析错
  let bad = client.request(@moonhttp.Config::new("/badjson"))
  try {
    ignore(bad.json())
    println("[badjson]   json() 没抛错（不应该）")
  } catch {
    _ =>
      println(
        "[badjson]   正文 = \{bad.text()}，json() 抛解析错误（符合预期）",
      )
  }
  println("")
}
