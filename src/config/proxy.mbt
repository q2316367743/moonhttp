// 代理配置：`ProxyProtocol` / `Proxy` 两个值类型，加上 `Config::with_proxy`。
// 与 Config 拆在不同文件，便于各自独立演进（也满足 AGENTS.md RL-04 的 300 行上限）。
// 构建器放在这里而不是 config.mbt，是为了让「代理相关的形状」集中在一处。

///|
/// 与代理服务器通信用的协议。
///
/// 用枚举而不是字符串：取值只有两个，拼错协议名应当是编译错误。
/// `Https` 表示**到代理本身**走 TLS（底层先与代理完成 TLS 握手，再在它上面发
/// `CONNECT`），与「目标地址是 https」是两件独立的事——后者在隧道建立之后
/// 还要再叠一层 TLS。
pub(all) enum ProxyProtocol {
  Http
  Https
} derive(Eq, Debug)

///|
pub extend ProxyProtocol with Eq::{equal, not_equal}

///|
pub extend ProxyProtocol with @debug.Debug::{to_repr}

///|
/// 协议名的小写取值（`http` / `https`）。
///
/// 一处实现两处用：`Proxy::to_string` 的渲染、以及拼代理服务器地址时的那一段
/// ——它们本来就该是同一个字符串，分开写迟早会不一致。
pub fn ProxyProtocol::to_string(self : ProxyProtocol) -> String {
  match self {
    Http => "http"
    Https => "https"
  }
}

///|
/// 代理服务器设置，对应 axios 的 `proxy`。
///
/// 每个字段都是 `Option`，与 `Config` 是同一套「`None` = 未提供」的语义，
/// 所以它的合并也是逐字段深合并：默认值给了 `host`、请求给了凭据，
/// 合并后两者都在（见 merge.mbt 的 `merge_proxy`）。
///
/// **只有 `host` 是必填的**：`protocol` 缺省 `Http`、`port` 缺省交给底层按协议补
/// （http 80 / https 443）、`auth` 缺省表示匿名代理。
/// 「给了 `proxy` 却没给 host」是配置错误：`is_usable()` 返回 `false`，
/// 上层据此报错，而不是当成没配代理。
pub(all) struct Proxy {
  /// 到代理服务器用 http 还是 https（TLS 到代理本身）；缺省 `Http`
  protocol : ProxyProtocol?
  /// 代理服务器的主机名或 IP
  host : String?
  /// 代理服务器端口；缺省由协议决定（http 80 / https 443）
  port : Int?
  /// 代理认证凭据（HTTP Basic）。只用于建立隧道时的 CONNECT 请求，
  /// **不会**发给目标服务器，见 `src/util/request.mbt`。
  auth : Auth?
} derive(Eq, Default, Debug)

///|
pub extend Proxy with Eq::{equal, not_equal}

///|
pub extend Proxy with Default::{default}

///|
pub extend Proxy with @debug.Debug::{to_repr}

///|
/// 渲染代理配置：与 `Auth::to_string` 一样，密码脱敏成 `<redacted>`
/// （代理凭据同样是凭据，配置进日志时不能明文泄漏）。
pub fn Proxy::to_string(self : Proxy) -> String {
  let buf = StringBuilder()
  let mut first = true
  match self.protocol {
    Some(protocol) =>
      first = push_field(buf, first, "protocol", protocol.to_string())
    None => ()
  }
  match self.host {
    Some(host) => first = push_field(buf, first, "host", host)
    None => ()
  }
  match self.port {
    Some(port) => first = push_field(buf, first, "port", port.to_string())
    None => ()
  }
  match self.auth {
    Some(auth) => first = push_field(buf, first, "auth", auth.to_string())
    None => ()
  }
  render_braced("Proxy", buf.to_string(), first)
}

///|
/// 这份代理配置能不能用：**必须给出非空的 host**。
///
/// 判定只做一次、两处复用：`@util.build_prepared_request` 用它决定「拼不出请求」
/// （返回 `None`），根包用它决定错误码与文案（`ERR_INVALID_URL`）。
///
/// 之所以不做「缺 host 就当成没配代理」的容错：那会让本该走代理的请求静默地
/// 直连出去，比直接报错危险得多。
pub fn Proxy::is_usable(self : Proxy) -> Bool {
  match self.host {
    Some(host) => !host.trim().is_empty()
    None => false
  }
}

///|
/// 设置代理服务器（对应 axios 的 `proxy` 对象）。
///
/// `host` 必填，其余可选——正因为只有它必填，正常写法下不会出现
/// 「有代理却没地址」的配置：
///
/// ```moonbit nocheck
/// Config::default().with_proxy("127.0.0.1", port=9000)
/// Config::default().with_proxy(
///   "proxy.corp", port=8443, protocol=ProxyProtocol::Https,
///   username="mikeymike", password="rapunz3l",
/// )
/// ```
///
/// `username` / `password` 只用于建立隧道时的 CONNECT 请求（Basic 认证），
/// 不会发给目标服务器；两者都不给则是匿名代理。只给其中一个时，另一半按空串
/// 参与编码——与 `with_auth` 的既有行为一致。
///
/// 作用范围：所有请求都经由代理（含 http 目标，本项目的底层统一走 CONNECT 隧道），
/// 跟随重定向时每一跳各建一次隧道。只支持 http/https 代理，不做 SOCKS；
/// 不读 `http_proxy` / `no_proxy` 环境变量，也不提供按请求关闭代理的开关
/// ——细节与理由见 `docs/09-proxy.md`。
pub fn Config::with_proxy(
  self : Config,
  host : String,
  port? : Int,
  protocol? : ProxyProtocol,
  username? : String,
  password? : String,
) -> Config {
  let auth = match (username, password) {
    (None, None) => None
    (username, password) => Some(Auth::{ username, password, })
  }
  { ..self, proxy: Some(Proxy::{ protocol, host: Some(host), port, auth, }), }
}
