// 七段用例：每段一个函数，由 `main.mbt` 的 `main` 依次调用。
// 靶子是 test/server.py 的 /cookies/* 与 /redirect/* 路由。

///|
/// 1. 种下 cookie：响应的 `Set-Cookie` 自动入库，后续请求按 URL 自动携带。
async fn login_and_carry(client : @moonhttp.Client) -> Unit {
  println("== 1. 种下 cookie → 自动携带 ==")
  ignore(
    client.request(
      @moonhttp.Config::new("/cookies/set?name=session&value=abc123"),
    ),
  )
  ignore(
    client.request(@moonhttp.Config::new("/cookies/set?name=theme&value=dark")),
  )
  show(
    client,
    "种下两个之后     ",
    @moonhttp.Config::new("/cookies/whoami"),
  )
  println("")
}

///|
/// 2. 显式 `Cookie` 头优先：注入走 set_if_absent，调用方 / 拦截器显式设置
/// 的头不被罐覆盖（与 Content-Type / Authorization 的补默认头同一口径）。
async fn explicit_header_wins(client : @moonhttp.Client) -> Unit {
  println("== 2. 显式 Cookie 头优先（罐只补空位）==")
  show(
    client,
    "显式 manual=1    ",
    @moonhttp.Config::new("/cookies/whoami").with_header("Cookie", "manual=1"),
  )
  println("")
}

///|
/// 3. 同名 `Set-Cookie`：新值替换旧值（同名覆盖沿用旧序号，位置不变）。
async fn overwrite(client : @moonhttp.Client) -> Unit {
  println("== 3. 同名 Set-Cookie：新值替换旧值 ==")
  ignore(
    client.request(
      @moonhttp.Config::new("/cookies/set?name=session&value=NEW999"),
    ),
  )
  show(
    client,
    "刷新 session 之后",
    @moonhttp.Config::new("/cookies/whoami"),
  )
  println("")
}

///|
/// 4. `Path` 限定：Path=/scoped 的 cookie 只随 /scoped 下的请求走。
async fn path_scope(client : @moonhttp.Client) -> Unit {
  println("== 4. Path 限定（/scoped 下的 cookie 不外流）==")
  ignore(
    client.request(
      @moonhttp.Config::new("/cookies/set?name=scoped&value=1&path=/scoped"),
    ),
  )
  show(client, "请求 /           ", @moonhttp.Config::new("/cookies/whoami"))
  show(client, "请求 /scoped/whoami", @moonhttp.Config::new("/scoped/whoami"))
  println("")
}

///|
/// 5. `Max-Age=0` 是删除信号：同名 cookie 移除，其余不受影响。
async fn expire(client : @moonhttp.Client) -> Unit {
  println("== 5. Max-Age=0：删除信号 ==")
  ignore(
    client.request(
      @moonhttp.Config::new("/cookies/set?name=session&value=&max_age=0"),
    ),
  )
  show(
    client,
    "删除 session 之后",
    @moonhttp.Config::new("/cookies/whoami"),
  )
  println("")
}

///|
/// 6. 派生实例与父实例共享**同一个**罐：`create` 是「同一个实例换套默认值」，
/// 不该丢登录攒下的会话状态（docs/19 对外契约）。
async fn derived_shares_jar(client : @moonhttp.Client) -> Unit {
  println("== 6. 派生实例共享同一个罐 ==")
  let derived = client.create(@moonhttp.Config::default())
  show(
    derived,
    "派生实例请求     ",
    @moonhttp.Config::new("/cookies/whoami"),
  )
  println("")
}

///|
/// 7. 跨 host 不带：cookie 按域匹配，`127.0.0.1` 名下的罐不会跟着跳到
/// `localhost`（与重定向剥 `Authorization` 的规则互补）。
///
/// `localhost` 在有些系统上先解析到 IPv6（::1）而靶子只听 IPv4——这条要是
/// 连不上是环境问题，错误分类会如实打印。
async fn cross_host(client : @moonhttp.Client) -> Unit {
  println("== 7. 跨 host 跳转：cookie 按域匹配自然不带 ==")
  try {
    let response = client.request(
      @moonhttp.Config::new("/redirect/cross-host").with_header(
        "Authorization", "Bearer secret",
      ),
    )
    let echoed = response.json() catch { _ => return }
    match echoed {
      { "authorization": String(auth), "cookie": String(cookie), .. } => {
        println(
          "终点收到的 Authorization = \{if auth == "" { "<被剥掉>" } else { auth }}",
        )
        println(
          "终点收到的 Cookie        = \{if cookie == "" { "<没带>" } else { cookie }}（127.0.0.1 的罐不跟到 localhost）",
        )
      }
      _ => println("终点回显不符合预期")
    }
  } catch {
    error =>
      println(
        "连不上 localhost（多为 IPv6 环境问题）：\{error.code()} / \{error.message()}",
      )
  }
  println("")
}
