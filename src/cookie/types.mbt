// cookie 包的数据形态：jar 里的一枚 cookie、存储键、以及 jar 本身。
// 行为（存 / 取 / 匹配 / 过期）在 jar.mbt，解析在 parse.mbt。

///|
/// jar 里的一枚 cookie：解析 Set-Cookie 并算好归属之后的存储形态（私有）。
priv struct Cookie {
  name : String
  value : String
  /// 归属域（小写主机名，不含端口）。host_only 时必须与请求 host 精确相等；
  /// 否则请求 host 等于它、或是「`.它`」结尾的后缀即匹配
  /// （RFC 6265 §5.1.3 的精简版，无公共后缀列表）
  domain : String
  /// 归属路径，以 `/` 开头（RFC 6265 §5.1.4）
  path : String
  /// Set-Cookie 没带 Domain 属性时为真：只发给当初设置它的那台主机
  host_only : Bool
  /// 带 Secure 属性：只随 https 请求发送
  secure : Bool
  /// 过期时刻（Unix 毫秒）；`None` = 会话 cookie，随 jar 存活
  expires_at : UInt64?
  /// 入库序号：同路径长度的 cookie 按它决定发送顺序（RFC 6265 §5.4）。
  /// 同名覆盖时沿用旧序号——RFC 把它当创建时间，覆盖不算重建
  serial : Int
}

///|
/// 存储键：归属域 + 归属路径 + 名字唯一确定一枚 cookie——
/// 同名不同域 / 不同路径是不同的 cookie（RFC 6265 §5.3 step 11）。
priv struct CookieKey {
  domain : String
  path : String
  name : String
} derive(Eq, Hash)

///|
/// cookie 存储罐：解析、归属、过期都自动完成，调用方只管喂 Set-Cookie、
/// 按 URL 取该带的 `Cookie` 头值。
///
/// 内部可变（`MockTransport` 同款模式）。一个 jar 可以挂到多个 `Client`
/// 上共享同一份会话状态；`Client::create` 派生的实例继承的也是**同一个**
/// jar（与拦截器链的继承口径一致）。
///
/// 已知边界（v1 有意不做）：没有公共后缀列表，`Domain=com` 这类属性不会被
/// 拒绝——`Domain` 只做「请求 host 的后缀」这一条校验（RFC 6265 §5.3 step 6）。
pub struct CookieJar {
  /// Map 本身是可变容器，字段无需 `mut`（改的是罐子里的内容，不是字段绑定）
  priv cookies : Map[CookieKey, Cookie]
  priv mut serial : Int
}

///|
/// 创建一个空 jar。作为 `Client::new(cookie_jar~)` 的入参挂到实例上之后，
/// 请求与响应的 cookie 维护就全自动了。
pub fn CookieJar::new() -> CookieJar {
  { cookies: Map([]), serial: 0, }
}
