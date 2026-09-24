// Config 类型本身与它的链式构建器。
// 渲染（to_string / Debug）在 render.mbt，小值类型（Auth / ResponseEncoding）在 types.mbt。

///|
/// 把 headers 包的 `Headers` 引入本包作用域，同时作为 `config` 公开 API 的一部分
/// 再导出——`Config` 的字段类型出现在签名里，使用者不该被迫再 import 一个包。
pub using @headers {type Headers}

///|
/// 一次请求的完整配置。它同时充当 axios 里的实例 `defaults` 与请求级 `config`，
/// 两者的区别只在合并时「谁覆盖谁」，形状完全一致。
///
/// 每个字段都是 `Option`，`None` 表示「这一项没有提供」。
/// 用 `Option` 而不是给每项塞一个哨兵默认值，是为了让「未提供」与
/// 「显式提供了一个恰好等于默认值的值」在合并时能被区分开——
/// 这是复刻 axios `mergeConfig` 语义的前提（那里用 JS 的 `undefined` 表达同一件事）。
///
/// 字段按合并策略分组，与 `merge` 包里的实现一一对应：
/// - 只取请求级（axios `valueFromConfig2`）：url / http_method / data
/// - 请求级优先、否则回退默认（`defaultToConfig2`）：
///   base_url / timeout / max_redirects / response_encoding / params_serializer /
///   on_upload_progress / on_download_progress / cancel_token
/// - 深合并（`mergeDeepProperties`）：
///   params / auth / proxy / headers / common_headers / method_headers / allow_absolute_urls
/// - 请求级存在即生效（`mergeDirectKeys`）：validate_status
///
/// 字段名用 `http_method` 而不是 axios 的 `method`：`method` 在 MoonBit 里
/// 是保留字，直接用作字段名会触发告警，也会让使用者写记录字面量时踩到。
/// 构建器仍保留短名 `with_method`，因为参数类型 `Method` 已经说明了语境。
///
/// 因为 `validate_status` / `params_serializer` / 两个进度回调都是函数类型字段，
/// 本类型不能 `derive(Debug)` 也不能 `derive(Eq)`，两者都是手写实现
/// （Debug 把函数渲染成 `<fn>`，需要比较配置时请逐字段比较）。
pub(all) struct Config {
  /// 请求地址；相对路径会和 `base_url` 拼接
  url : String?
  /// 请求方法，缺省为 `Method::Get`
  http_method : Method?
  /// 请求体：原样文本 / JSON / 表单 / URL 编码表单四种形态，
  /// 定义与序列化见 body.mbt、form.mbt。
  ///
  /// **这是本类型唯一的私有字段**：外部只能经 `with_data_from_str` /
  /// `with_data_from_json` / `with_data_from_form` / `with_data_from_urlencoded` 设置，
  /// 读法走 `serialize_body`。私有是为了让「设置 body」与「该补什么 Content-Type」
  /// 绑在一起——直接塞一个 `Json` 值没法表达「它是裸文本还是 JSON 字面量」，
  /// 也没法区分 JSON 与 urlencoded、承载带文件的表单。
  priv data : Body?
  /// 基础地址；`url` 是相对路径时会拼在它后面
  base_url : String?
  /// 超时毫秒数；`None` 或 `0` 表示不超时（与 axios 的 timeout 默认值 0 一致）。
  ///
  /// `request` 下是这条请求的时限；`stream` 下是**每次读取**的等待上限，
  /// 所以 SSE 这类「长时间没有数据是正常的」长连应保持不超时。
  timeout : Int?
  /// 最多跟随几次重定向，对应 axios 的 `maxRedirects`；默认 5。
  ///
  /// `0` 或负数表示不跟随：3xx 原样交出去，由 `validate_status` 判定成败。
  /// 跟随规则（哪些状态码跟、下一跳的方法 / body / 凭据怎么变）见 redirect.mbt。
  ///
  /// 每一跳各自受 `timeout` 约束，所以整条链的最坏耗时是「上限 × timeout」。
  max_redirects : Int?
  /// 响应体字节怎么解码成文本（`Response::text()` / `Response::json()` 用它）。
  /// 缺省（或未设置时）按 UTF-8 解码，非法字节用替换字符；
  /// 只在 `Client::request` 路径上生效。
  response_encoding : ResponseEncoding?
  /// 查询参数，序列化后追加到 URL（不覆盖 URL 里已有的 query）
  params : Json?
  /// 自定义 query 序列化器，对应 axios 的 `paramsSerializer`（函数形式）；
  /// `None` 表示用内置规则（`@url.serialize_params`，逐条规则见
  /// `docs/03-request-pipeline.md` 的「query 序列化」）。
  ///
  /// 传入的函数**整体替换**「`params` → query 文本」这一步：它拿到的就是 `params`
  /// 本身，返回的字符串就是 query 本体（不带前导 `?`）。拼接规则仍由 `build_url`
  /// 负责，与 axios 的 `buildURL` 一致——URL 里已有 `?` 时用 `&` 续接、丢弃
  /// `#fragment`、返回空串时不留下空分隔符。
  ///
  /// **只管 URL 的 query**：`with_data_from_urlencoded` 的请求体不走它
  /// （axios 里请求体走的是另一个内部选项 `formSerializer`，两者本就分开）。
  ///
  /// 与 axios 的差异：只接受函数形式，没有 `{ serialize, encode, indexes }`
  /// 那套对象形式，也没有单独定制某个组件编码器的口子。
  params_serializer : ((Json) -> String)?
  /// 上传进度回调，对应 axios 的 `onUploadProgress`；`None` 表示不报告进度。
  ///
  /// 请求体写入连接时逐块调用，构建器是 `with_on_upload_progress`，
  /// 触发入口、粒度与 `total` 的口径见 `progress.mbt` 与 `docs/10-progress.md`。
  on_upload_progress : ProgressCallback?
  /// 下载进度回调，对应 axios 的 `onDownloadProgress`；`None` 表示不报告进度。
  ///
  /// 只由库执行的「读全量」触发（`Client::request` / `StreamResponse::read_all`），
  /// 构建器是 `with_on_download_progress`。
  on_download_progress : ProgressCallback?
  /// 取消句柄，对应 axios 的 `cancelToken` / `signal`；`None` 表示这次请求不可取消。
  ///
  /// 语义（能打断什么、覆盖哪些入口、与 `timeout` / 重试的关系）见 cancel.mbt
  /// 与 `docs/12-cancellation.md`；构建器是 `with_cancel_token`。
  cancel_token : CancelToken?
  auth : Auth?
  /// 代理服务器设置，对应 axios 的 `proxy`；`None` 表示直连。
  ///
  /// 设了它就**必须给出 host**（判定见 `Proxy::is_usable`），否则报
  /// `ERR_INVALID_URL`——不做「缺 host 就当没配代理」的容错，那会让本该走代理的
  /// 请求静默直连。`auth` 里的凭据只用于建立隧道，不会发给目标服务器。
  /// 构建器是 `with_proxy`（与 `Proxy` 同文件，见 proxy.mbt），
  /// 字段语义与合并规则见 `docs/09-proxy.md`。
  proxy : Proxy?
  /// 请求级平铺的头，优先级最高
  headers : Headers?
  /// 默认值的 common 层头，优先级最低
  common_headers : Headers?
  /// 默认值的按方法分层的头，例如只给 GET 加的公共头
  method_headers : Map[Method, Headers]?
  /// 判定响应状态码是否算成功；缺省等价于 `200 <= status < 300`
  validate_status : ((Int) -> Bool)?
  /// `url` 已经是绝对地址时是否仍然直接使用（关闭后强制拼 `base_url`）
  allow_absolute_urls : Bool?
} derive(Default)

///|
pub extend Config with Default::{default}

///|
/// 以目标地址为起点构造一份请求配置，等价于 `Config::default().with_url(url)`。
///
/// `url` 是每次请求都必须提供的字段，把它做成构造参数，最常见的调用就能从
/// `Config::default().with_url("/users")` 缩短成 `Config::new("/users")`。
///
/// 之所以做成构造器而不是给 `Client::request` 加一个 `request(url, config?)`
/// 重载：MoonBit 不允许同一类型上有同名方法（会报
/// `The method request for type Client has been defined`），
/// 所以缩短调用点只能在 `Config` 这一侧做。
///
/// 注意这里设置的是**本次请求的目标地址**（`Config.url`），不是实例的基础地址。
/// 给实例设置基础地址请用 `Config::default().with_base_url(...)`：两者语义不同，
/// `url` 在合并时走「只取请求级」策略，放在实例默认值里不会生效。
pub fn Config::new(url : String) -> Config {
  { ..Config::default(), url: Some(url), }
}

///|
/// 链式构建器，例如：
///
/// ```moonbit nocheck
/// let config = Config::default()
///   .with_base_url("https://api.example.com")
///   .with_timeout(5000)
/// ```
///
/// 方法名统一加 `with_` 前缀，避免和同名字段访问冲突：
/// `config.url` 读字段，`config.with_url(...)` 才是返回值的新配置。
///
/// 每个构建器都返回新实例（immutable 风格），所以可以安全地把一个
/// 「模板配置」派生出多个变体，互不影响。
///
/// 例外：`with_proxy` 与 `Proxy` 类型同放在 proxy.mbt，便于「代理相关的一切」
/// 集中在一处（文件长度限制见 AGENTS.md RL-04）。
pub fn Config::with_url(self : Config, url : String) -> Config {
  { ..self, url: Some(url), }
}

///|
/// 设置请求方法。字段名是 `http_method`，这里保留 axios 风格的短名。
pub fn Config::with_method(self : Config, meth : Method) -> Config {
  { ..self, http_method: Some(meth), }
}

///|
/// 设置基础地址。
pub fn Config::with_base_url(self : Config, base_url : String) -> Config {
  { ..self, base_url: Some(base_url), }
}

///|
/// 设置超时（毫秒）。传 `0` 表示不限时。
pub fn Config::with_timeout(self : Config, timeout : Int) -> Config {
  { ..self, timeout: Some(timeout), }
}

///|
/// 设置最多跟随几次重定向。
///
/// 传 `0` 表示不跟随（3xx 直接交给 `validate_status` 判定，默认规则下会判成失败）；
/// `1` 表示只跟一跳。上限按「跳数」计，超过就抛 `ErrorCode::TooManyRedirects`。
pub fn Config::with_max_redirects(self : Config, max_redirects : Int) -> Config {
  { ..self, max_redirects: Some(max_redirects), }
}

///|
/// 设置响应体字节的解码方式（默认 `Utf8`）。
///
/// 只影响「读全量」的 `Client::request` 拿到的 `Response::text()`（以及
/// `json()` 里那一步解码）：`stream` 交原始字节、`sse` 按规范固定 UTF-8，
/// 都不读这个字段。
pub fn Config::with_response_encoding(
  self : Config,
  response_encoding : ResponseEncoding,
) -> Config {
  { ..self, response_encoding: Some(response_encoding), }
}

///|
/// 设置查询参数，通常直接传一个字面量 JSON 对象：
/// `with_params({ "page": 1, "tags": ["a", "b"] })`
pub fn Config::with_params(self : Config, params : Json) -> Config {
  { ..self, params: Some(params), }
}

///|
/// 设置 Basic 认证凭据。
pub fn Config::with_auth(
  self : Config,
  username : String,
  password : String,
) -> Config {
  {
    ..self,
    auth: Some(Auth::{ username: Some(username), password: Some(password), }),
  }
}

///|
/// 追加一条请求级头（优先级最高的一层）。同名头会被覆盖。
pub fn Config::with_header(
  self : Config,
  name : StringView,
  value : String,
) -> Config {
  let headers = match self.headers {
    Some(headers) => headers
    None => Headers::new()
  }
  { ..self, headers: Some(headers.set(name, value)), }
}

///|
/// 整体替换请求级头。需要一次设置多条时比连续调用 `with_header` 更清晰。
pub fn Config::with_headers(self : Config, headers : Headers) -> Config {
  { ..self, headers: Some(headers), }
}

///|
/// 追加一条 common 层头（默认值里最低优先级的一层）。
pub fn Config::with_common_header(
  self : Config,
  name : StringView,
  value : String,
) -> Config {
  let headers = match self.common_headers {
    Some(headers) => headers
    None => Headers::new()
  }
  { ..self, common_headers: Some(headers.set(name, value)), }
}

///|
/// 追加一条按方法分层的头，只在用该 `meth` 发请求时生效。
pub fn Config::with_method_header(
  self : Config,
  meth : Method,
  name : StringView,
  value : String,
) -> Config {
  // copy() 后再改：method_headers 可能来自别的 Config，
  // 直接改会让「模板配置」跟着变，破坏值语义。
  let buckets = match self.method_headers {
    Some(buckets) => buckets.copy()
    None => Map([])
  }
  let bucket = match buckets.get(meth) {
    Some(bucket) => bucket
    None => Headers::new()
  }
  buckets[meth] = bucket.set(name, value)
  { ..self, method_headers: Some(buckets), }
}

///|
/// 自定义状态码校验规则。传一个恒为 `true` 的函数即可关闭校验。
pub fn Config::with_validate_status(
  self : Config,
  validate_status : (Int) -> Bool,
) -> Config {
  { ..self, validate_status: Some(validate_status), }
}

///|
/// 设置 `url` 为绝对地址时是否仍然直接使用。
/// 设为 `false` 时，即使 `url` 是绝对地址也会被拼到 `base_url` 后面。
pub fn Config::with_allow_absolute_urls(
  self : Config,
  allow_absolute_urls : Bool,
) -> Config {
  { ..self, allow_absolute_urls: Some(allow_absolute_urls), }
}
