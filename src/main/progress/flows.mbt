// 四条流程：下载到 100%、真实下载 5% 取消、上传到 100%、上传 5% 取消。
// 靶子是本机 server（见 `main.mbt` 的 `drip_server` / `read_server`）与华为云大文件。

///|
/// 1. 下载进度：本机 server 分块慢吐 640 KiB，一路打印到 100%。
async fn local_download(client : @moonhttp.Client, port : Int) -> Unit {
  println("== 1. 下载进度（本机 drip server，10 块 × 64 KiB）==")
  let response = client.request(
    @moonhttp.Config::new("http://127.0.0.1:\{port}/drip").with_on_download_progress(
      percent_printer("下载", 10),
    ),
  )
  println("抓到的字节数 = \{response.bytes().length()}\n")
}

///|
/// 2. 真实大文件下载：打印百分比，进度到 5% 时取消。
///
/// 取消由**另一条协程**发出（看门狗，盯着进度回调报出来的数字）——
/// 这是本示例里唯一一处「不写在进度回调里」的取消，原因见下面的注释。
///
/// 取消后错误里带着**已经读到的那部分**响应，所以「下到一半停住」这件事
/// 有现场可查（下载方向尤其重要：不保住半截字节，重试就只能从头再来）。
async fn real_download_cancel(group : @async.TaskGroup[Unit]) -> Unit {
  println("== 2. 真实下载 + 5% 中途取消 ==")
  println("  靶子 = \{big_file_url}")
  let client = @moonhttp.create(
    @moonhttp.Config::default().with_timeout(120_000),
  )
  let token = @moonhttp.CancelToken::new()
  // 进度回调与看门狗之间的共享状态（回调是 noraise 的，只写不读）
  let percent_seen = Array::make(1, 0)
  let finished = Array::make(1, false)
  group.spawn_bg(no_wait=true) <| () => {
    // 看门狗：请求还在跑、进度到了 5% 就取消。
    //
    // 为什么不在进度回调里直接 `token.cancel()`：取消信号是投递到
    // 「被取消任务的下一个挂起点」的，从该任务内部（回调就跑在它里面）取消时
    // 信号会落在下一个 I/O 的**入口**上——HTTPS 下载在这条路径上会让原生进程
    // 直接崩溃（明文 HTTP 不会，本示例第 4 段上传就是这么写的）。
    // 换一条协程来取消，信号落在「已经挂起的 I/O」上，走的是正常路径。
    while !finished[0] && !token.is_cancelled() {
      @async.sleep(5)
      if percent_seen[0] >= cancel_at_percent {
        println(
          "  → 进度到 \{percent_seen[0]}% 了（看门狗协程发出取消）",
        )
        token.cancel(message="下载到 5% 就停")
      }
    }
  }
  let started = @async.now()
  let error = try {
    ignore(
      client.request(
        @moonhttp.Config::new(big_file_url)
        .with_cancel_token(token)
        .with_on_download_progress(
          percent_printer("下载", 5, on_percent=fn(percent) {
            percent_seen[0] = percent
          }),
        ),
      ),
    )
    None
  } catch {
    error => Some(error)
  }
  finished[0] = true
  print_cancel_outcome(error, started)
  // 取消确实生效了（进度停在 5%、半截响应在手），但 HTTPS 上错误分类**有时**会
  // 落到 ERR_NETWORK：取消链路先关连接、再中断读，两者谁先到是有竞争的——读先撞上
  // 「描述符已关闭」就报网络失败。明文 HTTP（第 4 段）没有这个问题。
  // 详见 docs/13-runnable-examples.md 的「已知问题」。
  match error {
    Some(error) if !error.is_cancelled() =>
      println(
        "  ↑ 取消生效了，但分类不是 ERR_CANCELED——HTTPS 上的已知问题（见 docs/13）",
      )
    _ => ()
  }
  println("")
}

///|
/// 3. 上传进度：8 MiB 载荷打本机 server（读得快），一路打印到 100%。
async fn upload_to_end(
  client : @moonhttp.Client,
  port : Int,
  payload : String,
) -> Unit {
  println("== 3. 上传进度（本机 server 快读，8 MiB 载荷）==")
  let response = client.request(
    @moonhttp.Config::new("http://127.0.0.1:\{port}/upload")
    .with_method(@moonhttp.Method::Post)
    .with_data_from_str(payload)
    .with_on_upload_progress(percent_printer("上传", 10)),
  )
  println("服务端回执 = \{response.status} \{response.text()}\n")
}

///|
/// 4. 上传中途取消：本机 server 读得慢，写动作必然堵在 socket 上，
/// 进度到 5% 时取消——报出去的是「已经写进连接的字节」，不是整个请求体。
async fn upload_cancel(
  client : @moonhttp.Client,
  port : Int,
  payload : String,
) -> Unit {
  println(
    "== 4. 上传 + 5% 中途取消（本机 server 慢读，制造背压）==",
  )
  let token = @moonhttp.CancelToken::new()
  let started = @async.now()
  let error = try {
    ignore(
      client.request(
        @moonhttp.Config::new("http://127.0.0.1:\{port}/upload")
        .with_method(@moonhttp.Method::Post)
        .with_data_from_str(payload)
        .with_cancel_token(token)
        .with_on_upload_progress(
          percent_printer("上传", 5, on_percent=fn(percent) {
            if percent >= cancel_at_percent && !token.is_cancelled() {
              println("  → 到 \{percent}% 了，取消")
              token.cancel(message="上传到 5% 就停")
            }
          }),
        ),
      ),
    )
    None
  } catch {
    error => Some(error)
  }
  print_cancel_outcome(error, started)
  println("")
}

///|
/// 把取消的结果打印成观察行（分类、描述、耗时、错误里带的半截响应）。
fn print_cancel_outcome(error : @moonhttp.HttpError?, started : Int64) -> Unit {
  match error {
    Some(error) => {
      println(
        "结果 = \{error.code()}：\{error.message()}（耗时 \{(@async.now() - started).to_int()} ms）",
      )
      match error.response() {
        Some(response) =>
          println(
            "错误里的半截响应 = \{response.status}，已收到 \{size_text(response.bytes().length())}",
          )
        None =>
          println(
            "错误里的响应 = <没有：请求体还没写完，还没到收响应那一步>",
          )
      }
    }
    None => println("结果 = 没抛错（不应该：取消没生效）")
  }
}
