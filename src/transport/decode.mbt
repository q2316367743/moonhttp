// 响应体解码：把按 `Content-Encoding` 编码过的字节还原成实体字节。
//
// 为什么放在 transport 而不是根包：`@gzip` / `@io` 属于 async 运行时那一侧，
// 纯逻辑的包（config / headers / util）不该碰它们。根包只调用这里的函数，
// 缓冲路径的解压不必自己 import 任何 async 包。
// 流式路径不经过这里：那一条由 httpconn 的 `@gzip.Decoder` 包分帧 reader 完成
// （谁解压谁声明，见 `docs/15-response-compression.md` 与 `docs/18`）。
//
// 谁在什么时候调用、失败怎么报、响应头怎么跟着变，见
// `docs/15-response-compression.md`。

///|
/// 响应头是否声明了 gzip 内容编码（`Content-Encoding: gzip`）。
///
/// 只认「整份值恰好是 gzip」这一种：按 RFC 9110，`Content-Encoding` 是逗号分隔的
/// 编码列表，多层编码（`gzip, gzip`）与别的编码（`br` / `deflate`）这里都返回
/// `false`——没有对应的解码器，认得更宽只会把**没解压的**字节当成实体字节交出去。
/// 值比较按大小写不敏感 + 裁空白（与 httpconn 流式解压的判定口径一致），头名比较由
/// `Headers::get` 负责。
///
/// 判定只有这一处：根包据此决定缓冲路径要不要解压（见 `docs/15-response-compression.md`）。
pub fn declares_gzip(headers : @headers.Headers) -> Bool {
  match headers.get("Content-Encoding") {
    Some(value) => value.trim().to_lower() == "gzip"
    None => false
  }
}

///|
/// 解压一整份 gzip 字节。
///
/// 只做内存里的数据变换：不碰网络、不做 IO、不看 HTTP 头——输入是已经读全的
/// 响应体。缓冲路径（`Client::request`）本来就先把响应体读全，解压因此能和
/// 「读」完全解耦，不必在流式读取的每一跳上挂解码器。
///
/// 实现借一个内存管道把两边接起来：`@gzip.Decoder` 只吃 `@io.Reader`，
/// 而我们手上是完整字节。写端放进后台任务一次性写完就关闭，读端交给解码器，
/// 这是 async 库官方自测里同一件事的写法。不假手 `ResponseBody`：它刻意不实现
/// `@io.Reader`（要命名 async 的内部类型，理由见 `docs/05-transport.md`）。
///
/// 失败一律报 `Malformed`（响应体与它声称的编码不符）：gzip 头非法、数据损坏、
/// 被截断（CRC32 / 长度校验不过、`NeedMoreInput`）都落在这一条上。宁可显式失败，
/// 也不把半截字节当正文交出去——上层据此报 `ERR_BAD_RESPONSE`，并把原始字节
/// 留在错误里（现场保真）。
pub async fn decode_gzip(data : Bytes) -> Bytes raise TransportError {
  let (reader, writer) = @io.pipe()
  try
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        defer writer.close()
        writer.write(data)
      }
      defer reader.close()
      @gzip.Decoder(reader).read_all().binary()
    }
  catch {
    // 解码器抛的是 async 内部包私有的 `FormatError` / `@io.ReaderClosed`：
    // 外部认不出来，也不该认——统一归成「响应体解不开」，文本原样带上。
    error => raise TransportError::Malformed(error.to_string())
  }
}
