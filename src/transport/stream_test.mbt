// 响应体流（ResponseBody）的读语义。
//
// 这里的用例只碰内存体：它的语义刻意对齐 @io.Reader，真实连接走同一套方法
// （见 stream.mbt），所以这里锁住的是「Mock 能真实代表网络」这件事。
// 真实连接的流式读取（边到边读、单次读取超时）由 httpconn 包的
// stream_real_test.mbt 验证——那里是现在唯一的真实传输实现。

///|
/// read_some：按 max_len 切块；读到 EOF 返回 None；close 之后继续读仍然是 None。
async test "response body reads in chunks until eof" {
  let body = @transport.ResponseBody::from_bytes(b"abcdef")
  assert_eq(body.read_some(max_len=2), Some(b"ab"))
  assert_eq(body.read_some(max_len=2), Some(b"cd"))
  // max_len 超过剩余量时只给剩下的，不会补齐也不会报错
  assert_eq(body.read_some(max_len=100), Some(b"ef"))
  assert_eq(body.read_some(max_len=2), None)
  body.close()
  assert_eq(body.read_some(max_len=2), None)
}

///|
/// read_all：一次读完剩余内容；已经读完之后再读是空的（而不是重新开始）。
async test "response body reads all remaining bytes" {
  let body = @transport.ResponseBody::from_bytes(b"hello world")
  assert_eq(body.read_all(), b"hello world")
  assert_eq(body.read_all(), b"")
}

///|
/// read_all_partial：正常读完时与 read_all 给出的字节一样，只是把「有没有失败」
/// 也交出来（这里是 `None`）。
///
/// 失败那一半（半截字节 + 错误）需要真实连接才能造出来，见根包
/// `error_test.mbt` 的两条超时用例；内存体上永远读得完，所以这里只钉住
/// 「成功路径不能因为多了个返回值就变形」。
async test "read_all_partial returns the bytes and no failure on the memory source" {
  let body = @transport.ResponseBody::from_bytes(b"hello")
  let (bytes, failure) = body.read_all_partial()
  assert_eq(bytes, b"hello")
  assert_true(failure is None)
  // 已读完（流已关闭）之后再读：空字节，依然没有失败
  let (again, failure) = body.read_all_partial()
  assert_eq(again, b"")
  assert_true(failure is None)
}

///|
/// read_until：分隔符被消费掉但不返回；末段没有分隔符时按 EOF 语义整段返回。
///
/// 用例里的中文是刻意选的：String 在 MoonBit 里是 UTF-16，按字节切只能得到
/// 合法的 UTF-8 序列，解码这一步（`@utf8.decode_lossy`）不能省。
async test "response body reads until separator" {
  let body = @transport.ResponseBody::from_bytes(
    b"data: \xe4\xb8\xad\xe6\x96\x87\n\ndata: tail",
  )
  assert_eq(body.read_until("\n\n"), Some("data: 中文"))
  assert_eq(body.read_until("\n\n"), Some("data: tail"))
  assert_eq(body.read_until("\n\n"), None)
}

///|
/// 为什么 SSE 不能用 `read_until("\n\n")` 切事件——这里把那个坑本身钉住。
///
/// CRLF 流上事件边界的字节是 `0D 0A 0D 0A`，里面**没有**连续两个 `0A`，
/// 所以按 `"\n\n"` 找分隔符是找不到的：内存体上表现为「没有分隔符 → 整段返回」，
/// 拿到的东西连边界都没切掉；在真实连接上更糟——EOF 不会来，
/// 于是会一直等到连接关闭（`timeout` 为不限时的 SSE 配置下就是永远等下去）。
///
/// 事件切分因此必须按三种行尾自己扫，见根包的 `SseParser`。
async test "read_until with two lf cannot cut crlf events" {
  let body = @transport.ResponseBody::from_bytes(b"data: x\r\n\r\n")
  // 一个分隔符都没找到，于是一整段（连边界都没切）原样返回
  assert_eq(body.read_until("\n\n"), Some("data: x\r\n\r\n"))
}
