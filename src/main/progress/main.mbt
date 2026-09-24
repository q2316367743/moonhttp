///|
/// 示例：上传 / 下载进度回调，以及「进度到 5% 时中途取消」。
///
/// 四段：
/// 1. 本机 drip server 下载到 100%（进度能到终点的样子）；
/// 2. 真实大文件下载（华为云 openjdk tar.gz），进度到 5% 就取消；
/// 3. 本机 server 上传 8 MiB 载荷到 100%；
/// 4. 本机「慢读」server 制造背压，上传进度到 5% 就取消。
///
/// 取消都发生在**进度回调里**：回调跑在可取消的子任务中，`cancel` 又是同步函数，
/// 所以「看到 5% 就喊停」是最自然的写法（机制见 docs/12-cancellation.md）。
/// 用 `moon run src/main/progress` 执行。本包只是示例，不随模块发布。
///
/// 取消百分比（进度回调里用它和当前百分比比较）。
let cancel_at_percent : Int = 5

///|
/// 真实下载的靶子：华为云 openjdk 镜像上的大文件（约 200 MB）。
let big_file_url : String = "https://mirrors.huaweicloud.com/openjdk/27/openjdk-27_macos-aarch64_bin.tar.gz"

///|
async fn main {
  @async.with_task_group() <| group => {
    // 三个本机靶子：分块慢吐（下载）、正常读（上传）、慢读（上传背压）
    let drip_port = drip_server(group, 10, 64 * 1024, 40)
    let sink_port = read_server(group, 0)
    let slow_port = read_server(group, 30)
    let client = @moonhttp.create(
      @moonhttp.Config::default().with_timeout(120_000),
    )
    println(
      "本机 server 已就绪：drip=127.0.0.1:\{drip_port} sink=127.0.0.1:\{sink_port} slow=127.0.0.1:\{slow_port}\n",
    )
    local_download(client, drip_port)
    real_download_cancel(group)
    let payload = payload_of(8 * 1024 * 1024)
    upload_to_end(client, sink_port, payload)
    upload_cancel(client, slow_port, payload)
  }
}

///|
/// 起一个「分 `chunks` 次吐正文、每次 `piece_size` 字节、间隔 `delay` 毫秒」的
/// 本机 server，返回端口。用来演示下载进度：节奏由服务端控制，输出可复现。
async fn drip_server(
  group : @async.TaskGroup[Unit],
  chunks : Int,
  piece_size : Int,
  delay : Int,
) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(allow_failure=true) <| ((_request, _body, conn) => {
      // 显式声明长度：真实服务端给静态文件也是这么回的，
      // 客户端据此算得出百分比（不声明的话就是 chunked，长度未知）
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/octet-stream",
        "Content-Length": (chunks * piece_size).to_string(),
      })
      let piece = "y".repeat(piece_size)
      for _ in 0..<chunks {
        conn..write_string(piece).flush()
        @async.sleep(delay)
      }
      conn.end_response()
    })
  }
  port
}

///|
/// 起一个「读完请求体再回 200」的本机 server，返回端口。
///
/// `read_delay` 是每读一块之后的停顿：0 表示读得快（上传能一口气跑到 100%），
/// 30 表示读得慢——客户端的写会堵在 socket 上，取消才有落点
/// （取消落在「正在写的那个挂起点」上，这也是它必须走协程级中断的原因）。
async fn read_server(group : @async.TaskGroup[Unit], read_delay : Int) -> Int {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(allow_failure=true) <| ((_request, body, conn) => {
      while body.read_some(max_len=64 * 1024) is Some(_) {
        if read_delay > 0 {
          @async.sleep(read_delay)
        }
      }
      conn..send_response(200, "OK")..write_string("done").end_response()
    })
  }
  port
}

///|
/// 造一份 `size` 字节的载荷：上传示例用它，省掉「先准备一个大文件」这一步。
fn payload_of(size : Int) -> String {
  let unit = "moonhttp-0123456789abcdef"
  let buf = StringBuilder()
  for _ in 0..<(size / unit.length()) {
    buf.write_string(unit)
  }
  buf.to_string()
}

///|
/// 把字节数渲染成人看的大小（KiB / MiB，一位小数）。
///
/// 用整数运算（Int64）而不是浮点，免得大文件上出现一长串小数位。
fn size_text(bytes : Int) -> String {
  let (unit, divisor) : (String, Int64) = if bytes < 1024 * 1024 {
    ("KiB", 1024)
  } else {
    ("MiB", 1048576)
  }
  let tenths = bytes.to_int64() * 10 / divisor
  "\{(tenths / 10).to_int()}.\{(tenths % 10).to_int()} \{unit}"
}

///|
/// 造一个「按百分比节流打印」的进度回调。
///
/// 真实下载按 64 KiB 一块会回调几千次，逐次打印会把控制台淹掉，
/// 所以只在整数百分比跨过 `step` 的倍数时打印一行。
/// `on_five_percent` 是可选钩子：示例用它演示「到 5% 就取消」。
fn percent_printer(
  label : String,
  step : Int,
  on_percent? : (Int) -> Unit,
) -> (@moonhttp.ProgressEvent) -> Unit {
  let last_percent = Array::make(1, -1)
  let last_bytes = Array::make(1, 0)
  fn(event) {
    match event.progress() {
      Some(ratio) => {
        let percent = (ratio * 100.0).to_int()
        if percent / step != last_percent[0] / step {
          last_percent[0] = percent
          println(
            "  \{label} \{percent}%（\{size_text(event.loaded)} / \{size_text(event.total.unwrap_or(0))}）",
          )
        }
        match on_percent {
          Some(callback) => callback(percent)
          None => ()
        }
      }
      // 长度未知（chunked、压缩、没给 Content-Length）时百分比算不出来，
      // 退回报告绝对字节数——这也是 `total` 是 Option 的原因。
      // 这条分支没有百分比可节流，按每 256 KiB 一行。
      None =>
        if event.loaded / (256 * 1024) != last_bytes[0] / (256 * 1024) {
          last_bytes[0] = event.loaded
          println(
            "  \{label} 已传 \{size_text(event.loaded)}（服务端未给长度，算不出百分比）",
          )
        }
    }
  }
}
