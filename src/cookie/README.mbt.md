# cookie —— Cookie 罐（解析 / 匹配 / 自动过期）

`CookieJar`：喂它 `Set-Cookie`、按 URL 问它该带什么 `Cookie` 头，解析、归属、过期全部自动。作为 `Client::new(cookie_jar~)` 的入参挂到实例上，请求与响应的 cookie 维护就全自动了（契约见 [docs/19-cookies.md](../docs/19-cookies.md)）。

```toml
import {
  "q2316367743/moonhttp/cookie",
}
```

## 语义

- **只做三件事**：`store`（喂 Set-Cookie）、`cookie_header`（按 URL 取头值）、过期自动失效。解析失败、URL 没有 host、`Domain` 不是请求 host 的后缀，一律静默忽略——坏 cookie 不报错，这是 RFC 6265 §5.3 的口径。
- **归属规则**：没带 `Domain` 属性是 host-only，只回当初那台主机；带了则对子域可见（前导点剥掉、大小写归一）。路径没带 `Path` 属性时按请求路径推导；`Secure` 只随 https 发送；端口不参与匹配。
- **自动过期**：`Max-Age` 优先于 `Expires`（只认标准 IMF-fixdate，如 `Sun, 06 Nov 1994 08:49:37 GMT`）；`Max-Age <= 0` 与已过期的 `Expires` 是删除信号；无过期属性 = 会话 cookie（随 jar 存活）。过期在读写时惰性清理。
- **发送顺序**：归属路径长的在前，同长度按入库先后；同名覆盖换值不换序。
- **显式头永远优先**：挂到 `Client` 上之后，注入走 `set_if_absent`——你自己在请求里设置的 `Cookie` 头不会被 jar 覆盖。
- **已知边界**：没有公共后缀列表（`Domain=com` 这类不会被拒绝）；`HttpOnly` 解析即弃；jar 不持久化，进程结束即失。

## API

| 方法 | 说明 |
|---|---|
| `CookieJar::new()` | 创建一个空罐 |
| `CookieJar::store(url, set_cookie)` | 喂一条 `Set-Cookie` 头值，按 `url` 算归属后存库或删除 |
| `CookieJar::cookie_header(url)` | 算出该请求该带的 `Cookie` 头值（`n1=v1; n2=v2`）；一个都不匹配时是 `None` |

## 用法

```moonbit nocheck
// 常规用法：挂到 Client 上，之后全自动
let jar = @cookie.CookieJar::new()
let client = @moonhttp.Client::new(cookie_jar=jar)
ignore(client.request(@moonhttp.Config::new("https://example.com/login")))
ignore(client.request(@moonhttp.Config::new("https://example.com/profile")))
```

```moonbit nocheck
// 也可以单独驱动：跨进程共享登录态前的手动喂取，或自己实现的传输层
let jar = @cookie.CookieJar::new()
jar.store("https://example.com/", "session=abc; Path=/; Max-Age=3600")
let header : String? = jar.cookie_header("https://example.com/profile")
// Some("session=abc")
ignore(header)
```

两个 `Client` 挂同一个罐即共享登录态；`instance.create(config)` 派生的实例与父实例共享的也是同一个罐。
