///|
/// 靶子地址：test/server.py 的默认端口（两处常量要一致，改一个得改另一个）。
let target_base : String = "http://127.0.0.1:18777"

///|
/// 示例：Cookie 自动维护（docs/19），七段：
///
/// 1. 种下 cookie → 后续请求自动携带；
/// 2. 显式 `Cookie` 头优先（罐只补空位，不覆盖）；
/// 3. 同名 `Set-Cookie` 新值替换旧值；
/// 4. `Path` 限定：/scoped 下的 cookie 不随别的路径走；
/// 5. `Max-Age=0` 是删除信号；
/// 6. 派生实例与父实例共享同一个罐；
/// 7. 跨 host（127.0.0.1 → localhost）不带 cookie。
///
/// 用 `moon run src/main/cookies` 执行。本包只是示例，不随模块发布。
async fn main {
  let client = @moonhttp.Client::new(
    config=@moonhttp.Config::default()
      .with_base_url(target_base)
      .with_timeout(10_000),
    cookie_jar=@moonhttp.CookieJar::new(),
  )
  println(
    "靶子 = \{target_base}（bash test/run.sh 或 python3 test/server.py 启动）\n",
  )
  login_and_carry(client)
  explicit_header_wins(client)
  overwrite(client)
  path_scope(client)
  expire(client)
  derived_shares_jar(client)
  cross_host(client)
}

///|
/// 「请求 → 服务端实际收到的 Cookie 头」（/cookies/whoami 的回显）。
fn seen_cookie(response : @moonhttp.Response) -> String {
  let echoed = response.json() catch { _ => return "<回显不是 JSON>" }
  match echoed {
    { "cookie": String(cookie), .. } =>
      if cookie == "" {
        "<没带>"
      } else {
        cookie
      }
    _ => "<回显不符合预期>"
  }
}

///|
/// 发一次请求并打印「服务端收到的 Cookie 头」——每段用例的证据行。
async fn show(
  client : @moonhttp.Client,
  label : String,
  config : @moonhttp.Config,
) -> Unit {
  let response = client.request(config)
  println("\{label} → 服务端收到：\{seen_cookie(response)}")
}
