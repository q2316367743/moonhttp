# 19 · Cookie 自动维护

`Client` 可以在**创建时**挂一个 cookie 罐（`CookieJar`），挂上之后请求与响应的
cookie 维护全自动：请求按 URL 自动携带、响应按 `Set-Cookie` 自动存取、
过期自动失效。不传罐时行为与从前完全一致（不会出现空的 `Cookie` 头）。

```moonbit
let jar = @moonhttp.CookieJar::new()
let client = @moonhttp.Client::new(cookie_jar=jar)
let _ = client.request(@moonhttp.Config::new("https://example.com/login"))   // 响应种 cookie
let _ = client.request(@moonhttp.Config::new("https://example.com/profile")) // 自动带上
```

## 对外契约

| 项 | 行为 |
|---|---|
| 传入位置 | 只有 `Client::new(cookie_jar~)`。jar 是有状态的运行时对象，**不进 `Config`**（与 `AbortSignal` 不进配置同理：它不该被逐请求合并） |
| 派生实例 | `client.create(config)` 与父实例共享**同一个** jar——`create` 是「同一个实例换套默认值」，不该丢登录攒下的会话状态（与拦截器链的继承口径一致） |
| 注入口径 | 每跳发出前走 `set_if_absent("Cookie", ...)`：用户 / 拦截器显式设置的 `Cookie` 头永远优先，与 Content-Type / Authorization 的补默认头一致 |
| 捕获时机 | 每跳 `transport.send` 返回**之后**立即入库——响应头到手即可种 cookie，不必等响应体读完（登录流的中途 3xx 一样有效；读体失败也不丢会话状态） |
| 重定向 | 注入与捕获都按**跳**执行：跨域时 jar 按域匹配自然不带旧域 cookie，与 `next_redirect` 剥显式 `Cookie` 头的规则互补（见 `08-redirects.md`） |
| 三个入口 | `request` / `stream` / `sse` 走同一条 `send_following_redirects`，行为完全一致 |

对外 `Response` / `StreamResponse` / `SseStream` **不变**：`Set-Cookie` 不上响应头
（见下），要读 cookie 就通过 jar；直接读原始 `Set-Cookie` 列表的需求
（`RawResponse.set_cookies`）留给后续版本再决定要不要上抬到门面。

## 前置改动：`RawResponse.set_cookies`

实现本功能前，`Set-Cookie` 在传输边界就丢了：multimap 压平成单值
`Headers` 只留最后一个值（已删除的旧栈更干脆：底层把 cookie 解析走、不放进 headers）。
所以第一步是给 `RawResponse` 加多值出口（`pub(all)` 结构加字段是**破坏性变更**，
版本随之升 0.4.0）：

- **现行**（`httpconn/transport.mbt` 的 `build_raw_response`）：压平循环里把
  `set-cookie`（大小写不敏感）逐条收进 `set_cookies`，**线上原文**。压平行为
  维持原样（`headers` 里仍是最后一个值——历史残留，不要依赖）；
  与旧栈从 `@http.Response::cookies` 序列化还原（属性顺序、扩展属性可能与原文不同）
  相比，原文保真是新栈的一个改进。

## cookie 包（`src/cookie/`）

纯逻辑包，不碰 async，同步测试覆盖（与 sse / headers / url 同一惯例）。
依赖 `url`（`url_host` / `url_path` / `url_scheme` 三个零件提取）与
`core/env`（`now()`，Unix 毫秒，过期判断的唯一时钟——不用 `@async.now()`
是为了不把 async 运行时拖进来）。

| 文件 | 内容 |
|---|---|
| `types.mbt` | `CookieJar`（`Map[CookieKey, Cookie]` + 入库序号，`MockTransport` 同款内部可变）、私有的 `Cookie` / `CookieKey`（键 = 域 + 路径 + 名字） |
| `parse.mbt` | `parse_set_cookie`（RFC 6265 §5.2：属性名大小写不敏感、坏值只丢属性不丢整条）与 `parse_http_date`（IMF-fixdate + Howard Hinnant 的 `days_from_civil` 日历换算） |
| `jar.mbt` | `store`（解析 → 归属 → 存 / 删）、`cookie_header`（过期清理 → 匹配 → 排序 → 拼头值）、域 / 路径匹配与默认路径 |

### 匹配规则（RFC 6265 精简版）

- **域**：没带 `Domain` 属性是 host-only，只回当初那台主机；带了则剥前导点、
  小写归一，请求 host 等于它或以 `.它` 结尾即匹配；`Domain` 不是请求 host 的
  后缀时整条忽略（§5.3 step 6）。**端口不参与匹配**（`url_host` 有意去端口）。
- **路径**：显式 `Path` 按段边界前缀匹配（`/foo` 匹配 `/foo/bar`、不匹配
  `/foobar`）；没带时按请求路径推导默认路径（去掉最后一个 `/` 及其后，§5.1.4）。
- **Secure**：只随 https 请求发送。
- **发送顺序**（§5.4）：归属路径长的在前；同长度按入库先后。同名覆盖**沿用
  旧序号**（序号当创建时间用，覆盖不算重建）。

### 过期

- `Max-Age` 优先于 `Expires`（§5.3 step 3）；`Max-Age <= 0` 与已过时刻的
  `Expires` 都是**删除信号**（移除同名 cookie）；
- `Expires` 只认标准 IMF-fixdate（`Sun, 06 Nov 1994 08:49:37 GMT`），认不出
  退化为会话 cookie；两位数年份的 RFC 850 与 asctime 两种过时格式有意不认；
- 无过期属性 = 会话 cookie，随 jar 存活（进程内）；
- 清理是**惰性**的：读 / 写时顺手删掉已过期的（过期键先收集、迭代后再删，
  避免遍历中改 Map）。

### 已知边界（v1 有意不做）

- **无公共后缀列表**：`Domain=com` 这类不会被拒绝，只做「请求 host 的后缀」
  校验。接入 PSL 意味着带一份会过期的数据，不属于这个库的体量；
- `HttpOnly` 解析出来直接丢弃（客户端库没有 JS 环境的概念）;
- jar 不持久化：进程结束即失（要跨进程复用，将来可以在 jar 上加导出 / 导入）。

## 根包接线（`src/client.mbt`）

- `Client` 加 `priv cookie_jar : @cookie.CookieJar?`；`Client::new` 加
  `cookie_jar?` 可选参数（放最后，缺省 `None`）；`Client::create` 原样继承；
- `Client::send_following_redirects`：首跳与重定向跳，发出前
  `self.attach_cookie(prepared)`（`set_if_absent` 注入）、返回后
  `self.capture_cookies(prepared.url, raw.set_cookies)`；
- `facade.mbt` 再导出 `@cookie.CookieJar`；根包 `moon.pkg` 加 import。

## 测试落点

- `src/cookie/cookie_test.mbt`（黑盒）：存取、域 / 路径 / 安全匹配、过期删除、
  Max-Age 优先、发送顺序、覆盖不换序、坏输入忽略；
- `src/cookie/cookie_wbtest.mbt`（白盒）：IMF-fixdate 已知值（含闰年
  2000-02-29）、Max-Age 语法、默认路径、路径 / 域匹配的全部边界；
- `src/cookie_test.mbt`（根包端到端）：入罐 → 携带、显式头优先、无 jar 行为
  不变、跨域重定向不泄露 / 同域链上携带、多条 Set-Cookie、`Max-Age=0` 删除、
  `stream` 入口同样生效、派生实例共享 jar。

## 改动时的联动

- 改匹配 / 过期规则 → 先在 `src/cookie/` 补用例，改完跑该包同步测试；
  行为变化对外可见时同步本文与 `README.mbt.md` 的 cookie 一节；
- 动 `RawResponse` 结构 → 同步 `05-transport.md` 的字段表与 `03-request-pipeline.md`；
- 动根包注入 / 捕获的落点 → 它必须在 `send_following_redirects` 的**每跳**
  上（与拦截器「整链只跑一次」相反），同步本文的对外契约表；
- 给 jar 加导出 / 导入（跨进程复用）时：只加在 `cookie` 包，根包不参与。
