///|
/// 测试用传输层：记录收到的每一份请求，并返回预置的响应。
///
/// 它本身就是「传输层可替换」这个设计的示范——不碰网络就能把
/// 合并 → 拼接 → 拍平 → 校验的完整流程跑一遍。
/// 使用方也可以用它在自己的测试里替换掉真实网络。
pub struct MockTransport {
  /// 按顺序记录收到过的请求，供测试断言
  priv received : Array[PreparedRequest]
  /// 响应队列：每次请求取一个；取完之后一直复用最后一个
  priv responses : Array[RawResponse]
  /// 已取用的响应个数
  priv mut cursor : Int
  /// 若为 `Some`，发送时直接抛出该错误，用于测试错误路径
  priv mut failure : TransportError?
}

///|
/// 构造一个始终返回同一响应的 Mock。
pub fn MockTransport::new(response : RawResponse) -> MockTransport {
  MockTransport::from_responses([response])
}

///|
/// 构造一个按队列依次返回响应的 Mock；队列用完后一直复用最后一个响应。
pub fn MockTransport::from_responses(
  responses : Array[RawResponse],
) -> MockTransport {
  { received: [], responses, cursor: 0, failure: None, }
}

///|
/// 构造一个总是失败的 Mock，用来验证错误分类与传播。
pub fn MockTransport::failing(error : TransportError) -> MockTransport {
  MockTransport::from_responses([]).with_failure(error)
}

///|
/// 设置失败错误，返回新的 Mock（`failure` 是可变字段，这里刻意返回新实例，
/// 让「构造—配置—使用」的写法保持一致）。
pub fn MockTransport::with_failure(
  self : MockTransport,
  error : TransportError,
) -> MockTransport {
  self.failure = Some(error)
  self
}

///|
/// 收到过的请求，按顺序。
pub fn MockTransport::received(self : MockTransport) -> Array[PreparedRequest] {
  self.received
}

///|
/// 最近一次收到的请求；一次都没发过时为 `None`。
pub fn MockTransport::last_request(self : MockTransport) -> PreparedRequest? {
  let length = self.received.length()
  if length == 0 {
    None
  } else {
    Some(self.received[length - 1])
  }
}

///|
/// 断言用的便捷入口：接收一个 `&Transport` 也能读出请求记录。
pub fn MockTransport::request_count(self : MockTransport) -> Int {
  self.received.length()
}

///|
pub impl Transport for MockTransport with fn send(self, request) {
  self.received.push(request)
  match self.failure {
    Some(error) => raise error
    None => ()
  }
  if self.responses.is_empty() {
    raise TransportError::Unsupported(
      "MockTransport 没有配置任何响应；请用 MockTransport::new 或 from_responses 构造",
    )
  }
  // 队列耗尽后复用最后一个响应，方便「同一个响应要被请求多次」的测试。
  let index = if self.cursor < self.responses.length() {
    self.cursor
  } else {
    self.responses.length() - 1
  }
  self.cursor = self.cursor + 1
  self.responses[index]
}

///|
pub extend MockTransport with Transport::{send}
