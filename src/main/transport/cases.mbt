// 十段用例：每段一个函数，由 `main.mbt` 的 `main` 依次调用。
// 靶子是 test/server.py（共享靶子，见 test/README.md）。

///|
/// 1. gzip 缓冲路径：门面声明 `gzip, identity`，响应声明 gzip 就解压；
/// 解压后 `Content-Encoding` / `Content-Length` 一并摘掉（头与体不能互相矛盾）。
async fn gzip_buffered(client : @moonhttp.Client) -> Unit {
  println("== 1. gzip（缓冲路径：门面声明，收到即解）==")
  let response = client.request(@moonhttp.Config::new("/gzip"))
  println(
    "服务端收到的声明 = \{response.headers.get("x-accept-encoding").unwrap_or("<无>")}（门面补的）",
  )
  println(
    "content-encoding = \{response.headers.get("content-encoding").unwrap_or("<已摘掉>")}",
  )
  let text = response.text()
  println(
    "正文             = \{head_text(text, 24)}……共 \{text.length()} 字符（解压后的原文）",
  )
  println("")
}

///|
/// 2. gzip 流式路径：门面不声明，httpconn 自己声明 `gzip` 并透明解压——
/// 调用方从 `stream` 里读到的直接是原文（docs/15「谁解压谁声明」）。
async fn gzip_stream(client : @moonhttp.Client) -> Unit {
  println("== 2. gzip（流式路径：httpconn 自声明，边收边解）==")
  let stream = client.stream(@moonhttp.Config::new("/gzip"))
  let bytes = stream.read_all()
  println(
    "服务端收到的声明 = \{stream.headers.get("x-accept-encoding").unwrap_or("<无>")}（httpconn 补的，只有 gzip）",
  )
  println(
    "content-encoding = \{stream.headers.get("content-encoding").unwrap_or("<已摘掉>")}（透明解压）",
  )
  let text = @utf8.decode_lossy(bytes)
  println(
    "正文             = \{head_text(text, 24)}……共 \{text.length()} 字符",
  )
  stream.close()
  println("")
}

///|
/// 3. `with_decompress(false)`：声明 `identity`，服务端据此不压缩，
/// 谁都不解压——响应头里的 `content-encoding` 本来就不会有。
async fn gzip_off(client : @moonhttp.Client) -> Unit {
  println("== 3. with_decompress(false)：声明 identity，谁都不压 ==")
  let response = client.request(
    @moonhttp.Config::new("/gzip").with_decompress(false),
  )
  println(
    "服务端收到的声明 = \{response.headers.get("x-accept-encoding").unwrap_or("<无>")}",
  )
  println(
    "content-encoding = \{response.headers.get("content-encoding").unwrap_or("<无>")}（服务端没压缩）",
  )
  println("正文             = \{head_text(response.text(), 24)}……")
  println("")
}

///|
/// 4. 用户自己声明 `Accept-Encoding: gzip`：原样透传（补默认头不覆盖显式头），
/// 但缓冲路径的承诺是「交出来的一定解压」，所以照样解、头照样摘。
async fn gzip_user_declared(client : @moonhttp.Client) -> Unit {
  println("== 4. 用户自己声明 Accept-Encoding: gzip ==")
  let response = client.request(
    @moonhttp.Config::new("/gzip").with_header("Accept-Encoding", "gzip"),
  )
  println(
    "服务端收到的声明 = \{response.headers.get("x-accept-encoding").unwrap_or("<无>")}（用户写的原样透传）",
  )
  println(
    "content-encoding = \{response.headers.get("content-encoding").unwrap_or("<已摘掉>")}",
  )
  println(
    "正文字符数       = \{response.text().length()}（与第 1 段相同才对）",
  )
  println("")
}

///|
/// 5. 大响应体：3 MiB 定长 + 2 MiB chunked——多 MiB 级别的分帧读取，
/// 字节数必须一个不差（库内部的缓冲增长不该吃掉或多吐字节）。
async fn large_bodies(client : @moonhttp.Client) -> Unit {
  println("== 5. 大响应体（定长 3 MiB / chunked 2 MiB）==")
  let sized = client.request(@moonhttp.Config::new("/bytes?n=3145728"))
  println(
    "Content-Length 分帧 = \{sized.bytes().length()} 字节（服务端声明 3145728）",
  )
  let streamed = client.stream(
    @moonhttp.Config::new("/bytes-chunked?n=2097152"),
  )
  println(
    "chunked 分帧        = \{streamed.read_all().length()} 字节（服务端声明 2097152）",
  )
  streamed.close()
  println("")
}

///|
/// 6. User-Agent：httpconn 给没设置的请求补默认值；
/// 调用方显式设置的同名头永远优先（补默认头走 set_if_absent）。
async fn user_agent(client : @moonhttp.Client) -> Unit {
  println("== 6. User-Agent：默认值与显式覆盖 ==")
  let default_ua = client.request(@moonhttp.Config::new("/echo"))
  println(
    "默认     = \{echo_header(default_ua, "user-agent")}（httpconn 补的）",
  )
  let custom = client.request(
    @moonhttp.Config::new("/echo").with_header("User-Agent", "my-app/1.0"),
  )
  println(
    "显式覆盖 = \{echo_header(custom, "user-agent")}（调用方写的优先）",
  )
  println("")
}

///|
/// 7. 连接失败的两条分类：拒连归网络错误（一个字都没发出去）；
/// 配置里既没 url 又没 base_url 归地址错误（拼不出请求）。
async fn connection_failures() -> Unit {
  println("== 7. 连接失败的两条分类 ==")
  let refused = @moonhttp.create(@moonhttp.Config::default().with_timeout(3000))
  show_error(
    "拒连（127.0.0.1:1）",
    refused,
    @moonhttp.Config::new("http://127.0.0.1:1/"),
  )
  let no_url = @moonhttp.create(@moonhttp.Config::default())
  show_error("缺 url            ", no_url, @moonhttp.Config::default())
  println("")
}

///|
/// 8. 超时：`timeout` 是毫秒，超了报 ECONNABORTED（与取消的 ERR_CANCELED 分得开）。
async fn timeout_case(client : @moonhttp.Client) -> Unit {
  println("== 8. 超时（timeout 200ms，靶子睡 800ms）==")
  show_error(
    "超时",
    client,
    @moonhttp.Config::new("/slow?delay=800").with_timeout(200),
  )
  println("")
}

///|
/// 9. 自定义方法（docs/16，自研栈解锁）：`Method::Other` 存原样发原样，
/// WebDAV 的 `PROPFIND` 开箱即用（旧栈受封闭枚举所限发不出）。
/// 拼不进请求行的 token 不值得一次握手：建连之前就拦下。
async fn custom_method(client : @moonhttp.Client) -> Unit {
  println("== 9. 自定义方法（PROPFIND 原样落线）==")
  let response = client.request(
    @moonhttp.Config::new("/method").with_method(
      @moonhttp.Method::Other("PROPFIND"),
    ),
  )
  let echoed = response.json() catch { _ => return }
  match echoed {
    { "method": String(meth), .. } =>
      println("PROPFIND            → 服务端收到方法 = \{meth}")
    _ => println("PROPFIND            → 回显不符合预期")
  }
  show_error(
    "非法 token（带空格）",
    client,
    @moonhttp.Config::new("/method").with_method(
      @moonhttp.Method::Other("BAD METHOD"),
    ),
  )
  println("")
}

///|
/// 10. HTTP/1.0 兼容（docs/17 口径 1）：靶子裸写一条 1.0 响应，
/// 没有 `Content-Length`——正文靠连接关闭收尾，自研栈的 EOF 分帧在这里验。
async fn http10(client : @moonhttp.Client) -> Unit {
  println("== 10. HTTP/1.0（无 Content-Length，靠连接关闭收尾）==")
  let response = client.request(@moonhttp.Config::new("/http10"))
  println(
    "状态行 = \{response.status} \{response.status_text}，正文 = \{response.text()}",
  )
  println("")
}

///|
/// 造一个「边生成边喂数据」的读取流：MemoryReader 的回调里按 64 KiB 一段
/// 写满 `total` 字节——正是流式上传要服务的「数据源不在内存里攒齐」场景。
fn make_upload_reader(total : Int) -> &@io.Reader {
  let piece = Bytes::make(65536, b'u')
  let reader : &@io.Reader = @io.MemoryReader() <| writer => {
    let mut sent = 0
    while sent < total {
      let take = if total - sent < piece.length() {
        total - sent
      } else {
        piece.length()
      }
      writer.write(piece.exact_view(start=0, end=take).to_owned())
      sent = sent + take
    }
  }
  reader
}

///|
/// 进度事件的 total 渲染：None / Some(n) 两态正是 chunked 与定长的分野。
fn progress_total(event : @moonhttp.ProgressEvent) -> String {
  match event.total {
    Some(value) => "Some(\{value})"
    None => "None"
  }
}

///|
/// 从 `/upload` 的回执里取 (分帧形态, 服务端实收字节数)——服务端视角才是证据。
fn upload_metrics(response : @moonhttp.Response) -> (String, Int) {
  let value = response.json() catch { _ => return ("<回显不是 JSON>", -1) }
  match value {
    { "framing": String(framing), "received_bytes": Number(received, ..), .. } =>
      (framing, received.to_int())
    _ => ("<回显不符合预期>", -1)
  }
}

///|
/// 11. 流式上传（docs/20）：请求体不再整块进内存——读取流由传输层边读边写。
/// 两种线上形态各打一次：
/// - 不给 content_length → `Transfer-Encoding: chunked`（进度 total 未知）；
/// - 给 content_length   → `Content-Length` 定长（进度 total 已知）。
async fn upload_stream(client : @moonhttp.Client) -> Unit {
  println("== 11. 流式上传（读取流作为请求体）==")
  let total = 3 * 1024 * 1024
  // 不声明长度：chunked 分帧，进度 total 是 None
  let chunked_events : Array[@moonhttp.ProgressEvent] = []
  let chunked = client.request(
    @moonhttp.Config::new("/upload")
    .with_method(@moonhttp.Method::Put)
    .with_data_from_stream(make_upload_reader(total))
    .with_on_upload_progress(fn(event) { chunked_events.push(event) }),
  )
  let (framing, received) = upload_metrics(chunked)
  println(
    "chunked 模式     ：服务端按 \{framing} 收到 \{received} 字节（发出 \{total}）",
  )
  let last = chunked_events[chunked_events.length() - 1]
  println(
    "上传进度（末次） = loaded \{last.loaded}，total \{progress_total(last)}（长度未知）",
  )
  // 声明长度：定长分帧，进度 total 已知
  let sized_events : Array[@moonhttp.ProgressEvent] = []
  let sized = client.request(
    @moonhttp.Config::new("/upload")
    .with_method(@moonhttp.Method::Put)
    .with_data_from_stream(make_upload_reader(total), content_length=total)
    .with_on_upload_progress(fn(event) { sized_events.push(event) }),
  )
  let (framing2, received2) = upload_metrics(sized)
  println(
    "定长模式         ：服务端按 \{framing2} 收到 \{received2} 字节（发出 \{total}）",
  )
  let last2 = sized_events[sized_events.length() - 1]
  println(
    "上传进度（末次） = loaded \{last2.loaded}，total \{progress_total(last2)}（声明长度）",
  )
  println("")
}
