// 响应体的 gzip 支持：缓冲路径（`Client::request`）由库声明并解压，
// 流式路径（`stream` / `sse`）由 httpconn 声明并流式解压（谁解压谁声明）。
//
// 规则表（谁声明、谁解压、响应头怎么变、失败怎么报）见
// `docs/15-response-compression.md` 与 `docs/18`。前半用 Mock 覆盖「库自己解压」
// 这条路（含失败分类与开关），后半起本机 server 覆盖真实连接上的两条路径。

///|
/// 把字节压成 gzip 流：用 async 自带的编码器造**真的** gzip 字节。
/// （手写字节串一旦抄错，用例证明的就只是「抄错的那份没人认识」。）
async fn gzip_bytes(data : Bytes) -> Bytes {
  let (reader, writer) = @io.pipe()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer writer.close()
      @gzip.Encoder(writer)..write(data).end()
    }
    defer reader.close()
    reader.read_all().binary()
  }
}

///|
/// 造一份带自定义响应头的响应（`raw_response` 只给 `Content-Type`，
/// gzip 用例要精确控制 `Content-Encoding` / `Content-Length`）。
fn gzip_response(
  status : Int,
  headers : @transport.Headers,
  body : Bytes,
) -> @transport.RawResponse {
  {
    status,
    status_text: "OK",
    headers,
    set_cookies: [],
    body: @transport.ResponseBody::from_bytes(body),
  }
}

///|
/// 「服务端声称这份响应是 gzip」的那组头。
fn gzip_headers(length : Int) -> @transport.Headers {
  @transport.Headers::new()
  .set("Content-Type", "application/json")
  .set("Content-Encoding", "gzip")
  .set("Content-Length", length.to_string())
}

///|
/// 缓冲路径：声明 gzip → 解压 → 摘掉那两个描述线上字节的头。
async test "request decompresses a gzip response and drops the encoding headers" {
  let payload = @utf8.encode("{\"msg\":\"中文 body 会被 gzip 压起来\"}")
  let compressed = gzip_bytes(payload)
  let (client, mock) = client_with(
    gzip_response(200, gzip_headers(compressed.length()), compressed),
  )
  let response = client.request(@moonhttp.Config::new("/gz"))
  // 正文是解压后的实体字节，两种读法都对得上
  assert_eq(response.bytes(), payload)
  assert_eq(response.text(), "{\"msg\":\"中文 body 会被 gzip 压起来\"}")
  // 被摘掉的两个头描述的是线上字节，交出去的体已经是实体字节
  assert_true(response.headers.get("Content-Encoding") is None)
  assert_true(response.headers.get("Content-Length") is None)
  assert_eq(response.content_length(), payload.length())
  // 请求侧确实声明了压缩：缓冲路径由库声明、也由库解压
  assert_eq(
    mock.last_request().unwrap().headers.get("Accept-Encoding"),
    Some("gzip, identity"),
  )
}

///|
/// 二进制内容与跨块的大 body 同样要正确还原（不能按文本或按单块处理）。
async test "request decompresses a gzip body larger than one chunk" {
  let payload = Bytes::makei(300_000, i => (i % 251).to_byte())
  let compressed = gzip_bytes(payload)
  let (client, _) = client_with(
    gzip_response(200, gzip_headers(compressed.length()), compressed),
  )
  let response = client.request(@moonhttp.Config::new("/gz"))
  assert_eq(response.bytes().length(), payload.length())
  assert_eq(response.bytes(), payload)
}

///|
/// `decompress: false`：请求侧改声明 `identity`，响应体原样交出，
/// 连 `Content-Encoding` 也一并保留——头与体始终一致。
async test "with_decompress false keeps the compressed bytes and the headers" {
  let payload = @utf8.encode("不压缩就别解")
  let compressed = gzip_bytes(payload)
  let (client, mock) = client_with(
    gzip_response(200, gzip_headers(compressed.length()), compressed),
  )
  let response = client.request(
    @moonhttp.Config::new("/raw").with_decompress(false),
  )
  assert_eq(response.bytes(), compressed)
  assert_eq(response.headers.get("Content-Encoding"), Some("gzip"))
  assert_eq(
    response.headers.get("Content-Length"),
    Some(compressed.length().to_string()),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("Accept-Encoding"),
    Some("identity"),
  )
}

///|
/// 用户自己声明过 `Accept-Encoding`：请求头一字不改（不被我们的默认值盖掉），
/// 但缓冲路径的承诺照旧——只要响应头说 gzip，读到的全量字节照样解。
async test "a user declared accept-encoding wins and the buffered path still decodes" {
  let payload = @utf8.encode("用户自己声明了 gzip")
  let compressed = gzip_bytes(payload)
  let (client, mock) = client_with(
    gzip_response(200, gzip_headers(compressed.length()), compressed),
  )
  let response = client.request(
    @moonhttp.Config::new("/gz").with_header("Accept-Encoding", "gzip"),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("Accept-Encoding"),
    Some("gzip"),
  )
  assert_eq(response.text(), "用户自己声明了 gzip")
}

///|
/// 声明了别的编码（`br` / `deflate` / 多值）就一个字都不动：既不解压也不报错。
/// 假装认识会得到「把没解压的字节当实体字节」这种更难查的错。
async test "an unsupported content-encoding is passed through untouched" {
  let raw = b"not really brotli"
  let (client, _) = client_with(
    gzip_response(
      200,
      @transport.Headers::new()
      .set("Content-Type", "text/plain")
      .set("Content-Encoding", "br"),
      raw,
    ),
  )
  let response = client.request(@moonhttp.Config::new("/br"))
  assert_eq(response.bytes(), raw)
  assert_eq(response.headers.get("Content-Encoding"), Some("br"))
}

///|
/// 响应体解不开时：报 `ERR_BAD_RESPONSE`（这不是网络故障），
/// 错误里带着**原始压缩字节**与那句「声称自己是 gzip」的头——现场保真。
async test "a corrupt gzip body fails with ERR_BAD_RESPONSE" {
  // 只有 gzip 的 10 字节头、没有数据块：解压必然失败
  let broken = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  let (client, _) = client_with(
    gzip_response(200, gzip_headers(broken.length()), broken),
  )
  let error = try {
    ignore(client.request(@moonhttp.Config::new("/broken")))
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(@moonhttp.HttpError(_)))
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::BadResponse)
  let failed = error.response().unwrap()
  assert_eq(failed.bytes(), broken)
  assert_eq(failed.headers.get("Content-Encoding"), Some("gzip"))
}

///|
/// 状态码本身也没通过校验时，**状态码优先**：404 的错误页解不开，
/// 说「404」比说「解压失败」有用；响应体与头照原样挂在错误上。
async test "a failed decode does not mask a status code failure" {
  let broken = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"
  let (client, _) = client_with(
    gzip_response(404, gzip_headers(broken.length()), broken),
  )
  let error = try {
    ignore(client.request(@moonhttp.Config::new("/missing")))
    None
  } catch {
    error => Some(error)
  }
  let error = error.unwrap()
  assert_eq(error.code(), @moonhttp.ErrorCode::BadRequest)
  let failed = error.response().unwrap()
  assert_eq(failed.status, 404)
  assert_eq(failed.bytes(), broken)
  assert_eq(failed.headers.get("Content-Encoding"), Some("gzip"))
}

///|
/// 进度口径：压缩响应的 `loaded` / `total` 都按**线上字节**算
/// （解压发生在读全量之后，所以两者永远同一个口径，`loaded` 不会超过 `total`）。
async test "download progress counts wire bytes for a gzip response" {
  let payload = Bytes::makei(200_000, i => (i % 251).to_byte())
  let compressed = gzip_bytes(payload)
  let events : Array[@moonhttp.ProgressEvent] = []
  let (client, _) = client_with(
    gzip_response(200, gzip_headers(compressed.length()), compressed),
  )
  let response = client.request(
    @moonhttp.Config::new("/gz").with_on_download_progress(fn(event) {
      events.push(event)
    }),
  )
  // 正文照旧是解压后的实体字节
  assert_eq(response.bytes(), payload)
  // 压缩确实发生了，否则下面那条「loaded 小得多」的断言没有意义
  assert_true(compressed.length() < payload.length())
  let last = events[events.length() - 1]
  assert_eq(last.loaded, compressed.length())
  assert_eq(last.total, Some(compressed.length()))
  for event in events {
    assert_true(event.loaded <= compressed.length())
  }
}

///|
/// 真实连接（缓冲路径）：本机 server 发一份 gzip 响应，库里解压成原文。
///
/// 这条同时钉住「请求侧确实声明了 gzip」的线上效果——服务端看到了声明，
/// 才会（在这个用例里：无论如何都）把正文压起来。
async test "async transport decodes a gzip response for the buffered path" {
  let payload = @utf8.encode("本机 server 发来的 gzip 正文")
  let compressed = gzip_bytes(payload)
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, _body, conn) => {
        conn
        ..send_response(200, "OK", extra_headers=gzip_extra_headers())
        .flush()
        let body : &@io.Data = compressed
        conn..write(body).end_response()
      })
    }
    let response = @moonhttp.Client::new().request(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/gz"),
    )
    assert_eq(response.text(), "本机 server 发来的 gzip 正文")
    // 解压后的响应头里不该再有那句话（`Content-Length` 由底层删掉、
    // `Content-Encoding` 由根包解压后摘掉，两边口径一致）
    assert_true(response.headers.get("Content-Encoding") is None)
    assert_true(response.headers.get("Content-Length") is None)
  }
}

///|
/// 真实连接（流式路径）：请求没声明压缩时，由 httpconn 自己声明 `gzip`
/// 并在响应侧流式解压——「谁解压谁声明」（docs/15 / docs/18），旧栈
/// 「底层库补声明、透明解压」的怪癖随旧栈一起删除了。
///
/// 同时钉住摘头口径：我们声明了我们解的，响应头里不该再留着
/// `Content-Encoding`（`Content-Length` 也一并摘掉，`total` 归 `None`）。
async test "streaming decompresses gzip that httpconn declared itself" {
  let payload = @utf8.encode("流式读到的 gzip 正文")
  let compressed = gzip_bytes(payload)
  let seen : Array[String] = ["<未收到请求>"]
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((request, _body, conn) => {
        let declared = match
          request.headers.get(@http.CaseInsensitiveString("accept-encoding")) {
          Some(value) => value
          None => "<没有声明>"
        }
        seen[0] = declared
        conn
        ..send_response(200, "OK", extra_headers=gzip_extra_headers())
        .flush()
        let body : &@io.Data = compressed
        conn..write(body).end_response()
      })
    }
    let stream = @moonhttp.Client::new().stream(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/gz"),
    )
    assert_eq(stream.read_all(), payload)
    assert_true(stream.headers.get("Content-Encoding") is None)
  }
  // 服务端看到的声明来自我们自己（httpconn 补的）：这正是「谁解压谁声明」
  assert_eq(seen[0], "gzip")
}

///|
/// `decompress` 的合并策略是「请求级优先」（与 `response_encoding` 同档）：
/// 实例默认关掉之后，请求级还能把它开回来。
async test "request level decompress overrides the instance default" {
  let payload = @utf8.encode("开关的合并")
  let compressed = gzip_bytes(payload)
  let (client, mock) = client_with(
    gzip_response(200, gzip_headers(compressed.length()), compressed),
  )
  let instance = client.create(
    @moonhttp.Config::default().with_decompress(false),
  )
  // 实例默认关掉 → 请求侧声明 identity、响应体原样交出来
  let raw = instance.request(@moonhttp.Config::new("/gz"))
  assert_eq(
    mock.last_request().unwrap().headers.get("Accept-Encoding"),
    Some("identity"),
  )
  assert_eq(raw.bytes(), compressed)
  // 请求级开回来 → 回到默认行为（声明 gzip 并解压）
  let decoded = instance.request(
    @moonhttp.Config::new("/gz").with_decompress(true),
  )
  assert_eq(
    mock.last_request().unwrap().headers.get("Accept-Encoding"),
    Some("gzip, identity"),
  )
  assert_eq(decoded.bytes(), payload)
}

///|
/// 流式路径上关掉解压：我们声明 `identity`，httpconn 便一概不动，
/// 字节与头都保持线上原样——「头里有 Content-Encoding」与「字节仍是压缩的」
/// 在这条路上也成立。
async test "streaming with decompress false keeps the compressed bytes" {
  let payload = @utf8.encode("流式不解压")
  let compressed = gzip_bytes(payload)
  let seen : Array[String] = ["<未收到请求>"]
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((request, _body, conn) => {
        let declared = match
          request.headers.get(@http.CaseInsensitiveString("accept-encoding")) {
          Some(value) => value
          None => "<没有声明>"
        }
        seen[0] = declared
        conn
        ..send_response(200, "OK", extra_headers=gzip_extra_headers())
        .flush()
        let body : &@io.Data = compressed
        conn..write(body).end_response()
      })
    }
    let stream = @moonhttp.Client::new().stream(
      @moonhttp.Config::new("http://127.0.0.1:\{port}/gz").with_decompress(
        false,
      ),
    )
    assert_eq(stream.read_all(), compressed)
    assert_eq(stream.headers.get("Content-Encoding"), Some("gzip"))
  }
  // 声明是我们发的（decompress: false 换来的 identity），httpconn 因此没有解压
  assert_eq(seen[0], "identity")
}

///|
/// 本机 server 用的响应头：声明 gzip，长度交给 server 自己算
/// （它按写入的字节数补 `Content-Length`）。
fn gzip_extra_headers() -> Map[@http.CaseInsensitiveString, String] {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers[@http.CaseInsensitiveString("Content-Encoding")] = "gzip"
  headers
}
