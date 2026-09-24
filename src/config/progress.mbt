// 上传 / 下载的进度回调（对应 axios 的 `onUploadProgress` / `onDownloadProgress`）。
//
// 为什么单独一个文件而不是留在 config.mbt：那里已经贴着 RL-04 的 300 行上限，
// 而进度这块是唯一搬得动的部分（字段必须留在结构体里）。与 `proxy.mbt` /
// `serializer.mbt` 同一思路——文件按功能分。
//
// 契约（粒度、total 从哪来、哪些入口触发）见 `docs/10-progress.md`。

///|
/// 一次进度回调带来的信息，对应 axios 原生 `ProgressEvent` 的核心两个字段。
///
/// 刻意只保留能直接从传输过程算出的量：`progress()` 之外的 `rate` / `estimated`
/// （速率与剩余时间）需要读时钟，`bytes`（本次回调新增的字节）由相邻两次回调
/// 相减也能得到——它们都不该由传输层假装知道。
///
/// 与 axios 的差异：没有 `upload` / `download` 布尔标记与原生 `event` 对象，
/// 方向由「哪个回调被调用」表达。
pub(all) struct ProgressEvent {
  /// 已传输的字节数。
  ///
  /// 上传时是**已写入连接**的字节（已交给内核，不代表对端已经收到）；
  /// 下载时是本次读取已取出的响应体字节。
  loaded : Int
  /// 这次传输的总字节数；`None` 表示长度未知
  /// （例如响应是 chunked 编码、没有 `Content-Length`），
  /// 对应 axios 的 `lengthComputable === false`。
  total : Int?
} derive(Debug)

///|
pub extend ProgressEvent with @debug.Debug::{to_repr}

///|
/// 已传输比例（0.0 ~ 1.0）。
///
/// `total` 未知或为 `0` 时返回 `None`——这时能回答的只有「已经传了多少字节」，
/// 编不出一个比例来。`loaded` 超过 `total` 时可能大于 1.0（见
/// `docs/10-progress.md` 的「为什么 total 可能不准」），这里不做截断。
pub fn ProgressEvent::progress(self : ProgressEvent) -> Double? {
  match self.total {
    Some(total) if total > 0 =>
      Some(self.loaded.to_double() / total.to_double())
    _ => None
  }
}

///|
/// 进度回调。
///
/// `noraise`：回调是在请求发送 / 响应读取的中途被调用的，它抛出的错误没有
/// 合理的归属方（既不属于这次请求的传输错误，也不该让整条请求失败），
/// 所以类型上就要求它不抛。想在回调里记日志、推 UI 状态都没问题。
///
/// **回调是同步执行的**：它占用请求本身的时间预算（上传回调落在 `timeout`
/// 覆盖的发送阶段里），所以别在里面做耗时的事。
pub type ProgressCallback = (ProgressEvent) -> Unit noraise

///|
/// 设置上传进度回调，对应 axios 的 `onUploadProgress`。
///
/// 请求体写入连接时按块调用：先写一段、刷出去，再报一次进度。
/// 触发时机、粒度与 `total` 的口径见 `docs/10-progress.md`。
///
/// ```moonbit nocheck
/// Config::new("/upload")
///   .with_data_from_form(form)
///   .with_on_upload_progress(fn(event) {
///     println("\{event.loaded} / \{event.total.unwrap_or(0)}")
///   })
/// ```
pub fn Config::with_on_upload_progress(
  self : Config,
  on_upload_progress : ProgressCallback,
) -> Config {
  { ..self, on_upload_progress: Some(on_upload_progress), }
}

///|
/// 设置下载进度回调，对应 axios 的 `onDownloadProgress`。
///
/// 只由**库执行的「读全量」**触发：`Client::request` 与
/// `StreamResponse::read_all`。按块读（`read_some` / `read_until`）与 SSE
/// 不触发——那两条路由调用方自己驱动，进度自己统计即可。
pub fn Config::with_on_download_progress(
  self : Config,
  on_download_progress : ProgressCallback,
) -> Config {
  { ..self, on_download_progress: Some(on_download_progress), }
}
