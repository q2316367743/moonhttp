///|
/// HTTP 客户端实例，对应 axios 的 `AxiosInstance`。
///
/// 实例是不可变的：`create` 不修改自身，而是返回一个继承了当前默认值的新实例。
/// 这样多个实例之间不会互相影响，也就不会出现 axios 里
/// 「改了全局 `axios.defaults` 影响所有实例」那类隐蔽的相互干扰。
pub struct Client {
  /// 该实例的默认配置（已叠加在内置默认值之上）
  priv defaults : Config
  /// 传输层实现，决定「真的发出去」由谁完成
  priv transport : &@transport.Transport
}

///|
/// 创建实例。
///
/// - `config`：叠加在**内置默认值**之上的用户配置，
///   对应 axios 里 `axios.create(config)` 的语义（`axios.defaults` 的位置由
///   `@config.defaults()` 固定提供）；
/// - `transport`：传输层实现，缺省是真正走网络的 `AsyncHttpTransport`；
///   测试或特殊场景可以注入自己的实现（例如 `MockTransport`）。
pub fn Client::new(
  config? : Config,
  transport? : &@transport.Transport,
) -> Client {
  let defaults = match config {
    Some(config) => @merge.merge_config(@config.defaults(), config)
    None => @config.defaults()
  }
  let transport : &@transport.Transport = match transport {
    Some(transport) => transport
    None => @transport.AsyncHttpTransport::new()
  }
  { defaults, transport, }
}

///|
/// 基于当前实例派生一个新实例，对应 axios 的 `instance.create(config)`。
///
/// 新实例的默认值是「本实例的默认值」叠加 `config`，因此会继承父实例的
/// `base_url`、公共头等设置。注意 axios 的 `instance.create` 合并的是
/// 该实例自己的 defaults、与全局 defaults 无关，这里的行为一致。
pub fn Client::create(self : Client, config : Config) -> Client {
  {
    defaults: @merge.merge_config(self.defaults, config),
    transport: self.transport,
  }
}

///|
/// 本实例的默认配置。返回的是不可变值，修改它请用 `create` 派生。
pub fn Client::defaults(self : Client) -> Config {
  self.defaults
}

///|
/// 发送一次请求并返回响应；任何失败都抛出 `HttpError`。
///
/// 步骤与 axios 的 `_request` 一致：
/// 1. 合并配置（实例默认值在下、本次请求配置在上）；
/// 2. 确定请求方法；
/// 3. 拼接完整地址并追加 query、拍平头、序列化 body；
/// 4. 交给传输层发送；
/// 5. 解析响应体、校验状态码。
///
/// 传输层的错误在这里被翻译成对外的 `ErrorCode`，
/// 所以调用方不需要认识 `moonbitlang/async` 的错误类型。
pub async fn Client::request(
  self : Client,
  config : Config,
) -> Response raise HttpError {
  // 1. 合并配置
  let merged = @merge.merge_config(self.defaults, config)
  // 2. 方法缺省时先回退到实例默认值，再回退到 HTTP 的默认约定 GET。
  //    axios 在 _request 里也是从 this.defaults.method 单独回退一次，
  //    因为合并时 method 走的是「只取请求级」策略。
  let meth = match merged.http_method {
    Some(meth) => meth
    None =>
      match self.defaults.http_method {
        Some(meth) => meth
        None => Method::Get
      }
  }
  let merged = { ..merged, http_method: Some(meth), }
  // 3. 地址、头、body
  let prepared = build_prepared_request(merged)
  // 4. 发送。传输层错误在这里收敛成对外的分类，调用方无需认识底层错误类型。
  let raw = self.transport.send(prepared) catch {
    @transport.TransportError::Timeout =>
      raise make_error("请求超时", ErrorCode::Timeout, merged, None)
    @transport.TransportError::Network(message) =>
      raise make_error(
        "网络请求失败：" + message,
        ErrorCode::Network,
        merged,
        None,
      )
    @transport.TransportError::Unsupported(message) =>
      raise make_error(
        "传输层不支持该请求：" + message,
        ErrorCode::NotSupported,
        merged,
        None,
      )
  }
  // 5. 解析响应体，再校验状态码
  let response = build_response(raw, merged)
  validate_response(response)
  response
}

///|
/// 创建实例的便捷入口，对应 `axios.create(config)`。
///
/// `config` 是位置参数（与 axios 的 `axios.create(config)` 一致），
/// 会叠加在内置默认值之上。不需要任何定制时用 `default_client()`；
/// 需要注入传输层（例如测试里换成 `MockTransport`）时用
/// `Client::new(config~, transport~)`。
pub fn create(config : Config) -> Client {
  Client::new(config~)
}

///|
/// 用内置默认值 + 真实传输层创建一个默认实例。
///
/// 与 axios 的全局 `axios` 不同，本模块没有可变的全局状态，
/// 所以这里是一个工厂函数而不是一个共享单例：
/// 想定制默认值请用 `create(...)` 创建，或从已有实例用 `client.create(...)` 派生。
pub fn default_client() -> Client {
  Client::new()
}
