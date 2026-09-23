///|
/// 内置默认值，对应 axios 的 `lib/defaults/index.js`。
///
/// 只包含本项目真正会读的字段：`withCredentials` / `proxy` / `transformRequest` /
/// `maxRedirects` 等暂不支持的能力不在这里出现（见 README 的「暂不支持」清单），
/// 免得出现「配置了但完全不生效」的字段。
///
/// `Client::new()` 用它作为最底层，用户在 `create(config)` 里传的配置合并在其之上。
pub fn defaults() -> Config {
  // 本项目把 axios 的 `headers: { common, get, post, ... }` 结构拆成了
  // common_headers 与 method_headers 两个字段；默认没有方法专属头，
  // 所以这里给一个空桶，用户可以用 `with_method_header` 追加。
  let method_headers : Map[Method, Headers] = Map([])
  {
    ..Config::default(),
    // axios 的 timeout 默认值是 0，含义是「不超时」。
    timeout: Some(0),
    // axios 的 responseEncoding 默认值是 'utf8'，这里显式放进默认值，
    // 让 client.defaults() 里看得见「响应体按什么解码」。
    response_encoding: Some(ResponseEncoding::Utf8),
    // axios 的 validateStatus 默认实现：只有 2xx 算成功。
    validate_status: Some(fn(status) { status >= 200 && status < 300 }),
    common_headers: Some(
      @headers.Headers::new().set("Accept", "application/json, text/plain, */*"),
    ),
    method_headers: Some(method_headers),
    // 与 axios 的 allowAbsoluteUrls 默认值一致：绝对地址直连，不拼 baseURL。
    allow_absolute_urls: Some(true),
  }
}
