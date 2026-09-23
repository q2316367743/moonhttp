///|
/// 这两个类型出现在 `PreparedRequest` / `RawResponse` 的公开签名里，
/// 因此随本包一起再导出，使用者不必为了构造一份请求再 import 两个包。
pub using @config {type Method}

///|
pub using @headers {type Headers}

///|
/// 交给传输层去发送的一份请求。
///
/// 到达这一步时，配置合并、`base_url` 拼接、query 序列化、头拍平都已经完成，
/// 所以它只包含「把字节发出去」真正需要的信息，不含任何配置语义。
/// 这样任何实现——真实的 HTTP、测试用的 Mock、将来可能的连接池——
/// 都只需要关心这一层，替换传输实现不会影响上层语义。
pub(all) struct PreparedRequest {
  /// 请求方法（与 Config 一样用 http_method，避开 MoonBit 的保留字 method）
  http_method : @config.Method
  /// 完整地址，已包含 `base_url` 拼接结果与序列化后的 query
  url : String
  /// 已按 common < 按方法 < 请求级 拍平的最终头集合
  headers : @headers.Headers
  /// 请求体字节；`None` 表示不带 body
  body : Bytes?
  /// 超时毫秒数；`None` 或 `<= 0` 表示不限时
  timeout : Int?
} derive(Debug)

///|
pub extend PreparedRequest with @debug.Debug::{to_repr}

///|
/// 传输层拿到的原始响应。
///
/// 刻意不叫 `Response`：上层对外的 `Response` 还要承担 JSON 解析、
/// 状态码校验等语义，那些不属于传输层的职责。
pub(all) struct RawResponse {
  status : Int
  status_text : String
  headers : @headers.Headers
  body : Bytes
} derive(Debug)

///|
pub extend RawResponse with @debug.Debug::{to_repr}

///|
/// 传输层错误：把「网络世界里可能出什么事」收敛成三种情况，
/// 上层再映射成对外的 `ErrorCode`。
///
/// 有了这层收敛，上层不需要 import 任何 async 相关的包，
/// 自定义传输实现也不需要知道底层用的是哪套 HTTP 库。
pub(all) suberror TransportError {
  /// 超时（底层抛出的超时会被映射到这里）
  Timeout
  /// 网络层失败：连接失败、DNS 解析失败、TLS 握手失败等
  Network(String)
  /// 请求还没发出去就失败了：协议不支持、地址非法等
  Unsupported(String)
}

///|
/// 传输层抽象：把一份准备好的请求发出去，拿回原始响应。
///
/// 用 trait 而不是直接调用异步 HTTP 库有两个目的：
/// 1. 把整个 async 运行时依赖关在实现里，上层（配置合并、URL 拼接、
///    错误映射）都能用普通同步测试覆盖；
/// 2. 使用方和测试可以注入自己的实现，不必真的发网络请求。
pub(open) trait Transport {
  async fn send(Self, PreparedRequest) -> RawResponse raise TransportError
}
