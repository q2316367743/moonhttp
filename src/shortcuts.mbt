// ============================================================================
// 快捷方法：七个 HTTP 动词对 `Client::request` 的薄封装（`docs/14-shortcut-methods.md`）。
//
// 每个方法只做两件事——补上 `url` 与动词，然后转调 `request`。管线一个字节都
// 不复制：配置合并（实例默认值 + 本次请求）、三层头拍平、两段拦截器、自动
// 重定向、进度回调、取消、状态码校验全都还是 `request` 那一套。这也是它们
// 敢叫「薄封装」的底气，改动 `request` 的语义时不需要同步这里。
//
// 三条契约（用例在 `src/shortcut_test.mbt`）：
//   1. **`url` 位置参数永远赢**：传入的 `config` 自带 `url` 时也以它为准
//      （对齐 axios 的 `axios.get(url, config)`）；
//   2. **动词永远赢**：`config` 里的 `with_method(...)`、以及实例默认方法，
//      都盖不掉「`api.get(...)` 一定是 GET」这件事；
//   3. **不给 `config` 时**按「只有 url 的一份请求级配置」起步（`Config::new(url)`）。
//
// 请求体不进参数列表：它由 `config` 的 `with_data_from_*` 决定形态（四种形态
// 一视同仁，见 `docs/07-request-body.md`）。也**没有** `stream` / `sse` 的快捷
// 方法——那两个入口的返回类型不同，凑成 `get_stream` 之类只会污染 API。
//
// 本文件是根包文件且不足 300 行，不需要 RL-04 的例外声明。
// ============================================================================

///|
/// 七个快捷方法共用的实现：补 `url` 与动词，其余原样交给 `request`。
///
/// `config` 用 `config?` 透传（不是 `config~`）：可选参数的 `f(x?)` 形式才是
/// 「把 `Config?` 原样转发下去」，写 `config~` 会因类型是 `Config` 而不是
/// `Config?` 报错。
async fn Client::send_verb(
  self : Client,
  url : String,
  meth : @config.Method,
  config? : Config,
) -> Response raise HttpError {
  // 没给 config 就按「只有 url」起步；给了也照样把 url 覆盖上去——契约 1。
  let config = match config {
    Some(config) => config
    None => Config::new(url)
  }
  self.request(config.with_url(url).with_method(meth))
}

///|
/// 一次 GET 请求。契约见文件头：`url` 赢过 `config.url`，动词赢过
/// `config.http_method` 与实例默认方法，其余（实例默认值、拦截器、重定向、
/// 进度、取消、状态码校验）与 `client.request(...)` 完全一致。
pub async fn Client::get(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Get, config?)
}

///|
/// 一次 POST 请求。请求体由 `config` 给出，例如
/// `Config::default().with_data_from_json(...)` 或 `with_data_from_form(...)`；
/// 快捷方法不接请求体参数（四种请求体形态一视同仁）。
pub async fn Client::post(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Post, config?)
}

///|
/// 一次 PUT 请求。请求体的给法与 `post` 相同（走 `config.with_data_from_*`）。
pub async fn Client::put(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Put, config?)
}

///|
/// 一次 DELETE 请求。有些服务端要求 DELETE 也带请求体，同样由
/// `config.with_data_from_*` 给出。
pub async fn Client::delete(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Delete, config?)
}

///|
/// 一次 PATCH 请求。请求体的给法与 `post` 相同（走 `config.with_data_from_*`）。
pub async fn Client::patch(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Patch, config?)
}

///|
/// 一次 HEAD 请求。响应没有正文，`Response::text()` 读到的是空串；
/// 想拿响应头之外的元信息（如 `Content-Length`）用它最省。
pub async fn Client::head(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Head, config?)
}

///|
/// 一次 OPTIONS 请求（询问服务端支持哪些方法 / CORS 预检那类用途）。
pub async fn Client::options(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Options, config?)
}
