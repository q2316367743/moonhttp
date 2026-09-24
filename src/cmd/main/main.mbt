///|
/// 可运行示例：用真实网络演示这个 axios 风格客户端的基本用法。
///
/// 覆盖三件事：
/// 1. 创建实例，并让实例携带 `base_url` 等默认配置；
/// 2. 用 `request` 发请求，配置在「内置默认值 → 实例默认值 → 本次请求」之间合并；
/// 3. 读取响应（`text()` 是解码后的原文、`bytes()` 是精确字节、`json()` 才解析）、
///    以及状态码校验失败时的错误处理。
///
/// 用 `moon run src/cmd/main` 执行（需要联网）。
async fn main {
  // 1) 创建实例：base_url 与公共头都写在实例的默认配置里，
  //    后续每次请求不必重复设置；config 会叠加在内置默认值之上。
  let api = @moonhttp.create(
    @moonhttp.Config::default()
    .with_base_url("https://api.github.com")
    .with_timeout(10_000)
    .with_common_header("Accept", "application/vnd.github+json"),
  )
  println("实例的默认配置：\{api.defaults()}")

  // 2) 纯文本响应：`text()` 是按 response_encoding（默认 utf-8）解码出的原文，
  //    库不做任何 JSON 解析，所以文本可以原样打印。
  let zen = api.request(@moonhttp.Config::new("/zen"))
  println("\n[GET /zen] 状态码 = \{zen.status} \{zen.status_text}")
  println("响应体 = \"\{zen.text()}\"")
  println(
    "x-ratelimit-limit = \{zen.headers.get("x-ratelimit-limit").unwrap_or("<none>")}",
  )

  // 3) JSON 响应：解析这一步由调用方决定——库不猜内容类型，
  //    这样 `text/plain` 的 `123` 也不会被悄悄解成数字。
  //    示例里假定服务端返回的一定是合法 JSON，用 try! 直接暴露解析错误。
  let repo = api.request(@moonhttp.Config::new("/repos/moonbitlang/core"))
  println("\n[GET /repos/moonbitlang/core] 状态码 = \{repo.status}")
  match (try! repo.json()) {
    {
      "full_name": String(name),
      "stargazers_count": Number(stars, ..),
      "language": String(language),
      ..
    } =>
      println("解析结果 = \{name} / \{language} / \{stars.to_int()} stars")
    _ => println("解析结果 = \{repo.text()}")
  }

  // 4) 查询参数与实例派生：create 派生出的实例继承父实例的 base_url，
  //    再叠加本次的配置。
  let search = api.create(@moonhttp.Config::default().with_timeout(15_000))
  let found = search.request(
    @moonhttp.Config::new("/search/repositories").with_params({
      "q": "moonbit",
      "sort": "stars",
      "per_page": 3,
    }),
  )
  println("\n[GET /search/repositories?q=moonbit&sort=stars&per_page=3]")
  match (try! found.json()) {
    { "items": Array(items), .. } => {
      println("拿到 \{items.length()} 个仓库，前三个是：")
      for item in items {
        match item {
          { "full_name": String(name), .. } => println("  - \{name}")
          _ => ()
        }
      }
    }
    _ => println("响应不符合预期：\{found.text()}")
  }

  // 5) 错误处理：默认只把 2xx 当作成功，404 会抛出 HttpError，
  //    错误上带着分类、已合并的配置以及服务端返回的响应。
  ignore(
    api.request(
      @moonhttp.Config::new("/repos/moonbitlang/definitely-not-a-real-repo"),
    ),
  ) catch {
    @moonhttp.HttpError(info) => {
      println("\n[GET 不存在的仓库] 按预期失败")
      println("  错误分类 = \{info.code}")
      println("  错误描述 = \{info.message}")
      println("  服务端状态码 = \{info.response.unwrap().status}")
      println("  服务端的错误正文 = \{info.response.unwrap().text()}")
    }
  }
}
