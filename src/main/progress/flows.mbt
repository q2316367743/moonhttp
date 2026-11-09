// 四条流程：下载到 100%、真实下载 5% 取消、上传到 100%、上传 5% 取消。
// 靶子是本机 server（见 `main.mbt` 的 `drip_server` / `read_server`）与华为云大文件。

///|
/// 1. 下载进度：本机 server 分块慢吐 640 KiB，一路打印到 100%。
async fn local_download(client : @moonhttp.Client, port : Int32) -> Unit {
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
/// 取消直接写在进度回调里（回调跑在读全量的子任务里，同步 `abort` 立刻生效）。
/// 曾经 HTTPS 上这条路会让进程崩溃（取消同步关闭 TLS 后循环还去读），
/// 2026-11-09 已在 `drain_into` 里修掉，回归用例见
/// `src/transport/stream_cancel_progress_test.mbt`。
async fn real_download_cancel() -> Unit {
  println("== 2. 真实下载 + 5% 中途取消 ==")
  println("  靶子 = \{big_file_url}")
  let client = @moonhttp.create(
    @moonhttp.Config::default().with_timeout(120_000),
  )
  let controller = @moonhttp.AbortController::new()
  // 信号随请求走；叫停要拿控制器
  let signal = controller.signal()
  let started = @async.now()
  let error = try {
    ignore(
      client.request(
        @moonhttp.Config::new(big_file_url).with_on_download_progress(
          percent_printer("下载", 5, on_percent=fn(percent) {
            if percent >= cancel_at_percent && !signal.aborted() {
              println("  → 进度到 \{percent}% 了，取消")
              controller.abort(reason="下载到 5% 就停")
            }
          }),
        ),
        signal~,
      ),
    )
    None
  } catch {
    error => Some(error)
  }
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
  port : Int32,
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
  port : Int32,
  payload : String,
) -> Unit {
  println(
    "== 4. 上传 + 5% 中途取消（本机 server 慢读，制造背压）==",
  )
  let controller = @moonhttp.AbortController::new()
  let signal = controller.signal()
  let started = @async.now()
  let error = try {
    ignore(
      client.request(
        @moonhttp.Config::new("http://127.0.0.1:\{port}/upload")
        .with_method(@moonhttp.Method::Post)
        .with_data_from_str(payload)
        .with_on_upload_progress(
          percent_printer("上传", 5, on_percent=fn(percent) {
            if percent >= cancel_at_percent && !signal.aborted() {
              println("  → 到 \{percent}% 了，取消")
              controller.abort(reason="上传到 5% 就停")
            }
          }),
        ),
        signal~,
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
