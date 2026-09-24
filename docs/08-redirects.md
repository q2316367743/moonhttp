# 08 自动重定向

对应 axios 的 `maxRedirects`：3xx + `Location` 时自动跟到新地址，默认最多跟 5 跳，超限抛 `ErrorCode::TooManyRedirects`。三个入口（`request` / `stream` / `sse`）都跟随，规则逐条对齐 axios 在 Node 上用的 follow-redirects。

一句话概括实现：**「要不要跟随、下一跳长什么样」是纯逻辑（`config` 包），计数与发送循环是编排（根包）**，两者分开测试。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/config/redirect.mbt` | `Config::next_redirect`：跟随判定与下一跳构造（方法 / body / 凭据 / 头的改写规则全在这里） |
| `src/config/redirect_test.mbt` | 逐条钉住上面那些规则的同步用例（不需要传输层） |
| `src/client.mbt` | `Client::send_following_redirects`：计数、发下一跳、关掉 3xx 的连接、超限抛错 |
| `src/url/resolve.mbt` | `resolve_url`（RFC 3986 相对解析）、`url_scheme` / `url_authority`（凭据判定用的地址零件） |
| `src/redirect_test.mbt` | 端到端用例：跟随、改写、上限、关开关、跨 host 丢凭据、流式入口、真实连接 |
| `src/http_error.mbt` | `ErrorCode::TooManyRedirects` 与 `too_many_redirects_error` |

## 为什么规则在 `config` 包、循环在根包

下一跳的配置里要**清空请求体**（方法改成 GET 时），而 `Config.data` 是私有字段——包外连记录展开都写不出来，所以「构造下一跳的 `Config`」只能在 `config` 包内完成。顺带的好处是这些规则可以用纯同步用例覆盖，不需要 Mock 传输层。

循环本身做不到放进 `config`：它要调 `Transport::send`（异步）、要在跟随前关掉 3xx 的响应体、要数跳数，这些都得认识传输层与对外错误。所以分成「纯规则 + 薄循环」两半，循环里剩下的逻辑只有计数、关闭与错误翻译。

## 要不要跟随，跟几次

| 条件 | 行为 |
|---|---|
| 状态码不在 `[300, 400)` | 不跟随，响应原样交出去 |
| 3xx 但没有 `Location`，或值是空白 | 不跟随（follow-redirects 的 `!location` 分支），响应落进状态码校验 |
| 3xx + 非空 `Location`，`max_redirects > 0` | 跟随，最多 `max_redirects` 跳 |
| 第 `max_redirects + 1` 个重定向 | 抛 `ErrorCode::TooManyRedirects` |
| `max_redirects <= 0` | 完全不跟随：3xx 交给 `validate_status`（默认 2xx 规则下报 `BadResponse`，响应含 `Location` 挂在错误上） |

默认值是 **5**：axios 请求配置文档里写的就是 `maxRedirects: 5`。它底层用的 follow-redirects 自己兜底是 21，文档与实现并不一致，本项目取文档口径；`Config::default()`（未经 `defaults()` 的裸配置）在运行时也按 5 兜底。

`max_redirects <= 0` 与 axios 的 `maxRedirects: 0` 等价：那种配置下 axios 连 follow-redirects 都不进，直接把 3xx 当普通响应返回。区别只在负数——axios 会在第一次重定向时报错，本项目统一按「不跟随」处理（一条规则比两条好记）。

## 下一跳怎么构造

`Config::next_redirect(current_url, status, location)` 返回下一跳的配置；`current_url` 是**实际发出去**的地址（已含 `base_url` 拼接结果与序列化后的 query），相对 `Location` 相对它解析。

| 项 | 规则 |
|---|---|
| `url` | `Location` 按 RFC 3986 相对解析（含 `../` 点段归并），结果**去掉 fragment**；`base_url` 与 `params` 清空 |
| `http_method` | 301/302 上的 POST → `GET`；303 上除 GET/HEAD 之外 → `GET`；其余（含 307/308、301/302 上的 PUT/PATCH）保持原方法 |
| `data` | 只有方法被改写成 GET 时才丢（GET 不该带实体） |
| `content-*` 头 | 与方法同上：改写成 GET 时删掉三层头里所有 `content-*`（`Content-Type` / `Content-Length` / `Content-Encoding`…） |
| 凭据 | 见下节；丢掉时连 `auth` 字段一起清（否则下一跳会把 `Authorization` 补回来） |
| `Host` 头 | 每一跳都删掉（重定向可能换 host，Host 由传输层按新地址重新生成） |
| 其余字段 | `timeout` / `max_redirects` / `validate_status` / `response_encoding` / 各层头…原样保留 |

三个容易看漏的点：

- **`base_url` 与 `params` 必须清空**：解析出来的已经是绝对地址，query 早就在里面了，留着它们会被 `build_full_path` 再拼一次、被 `build_url` 再追加一次。
- **`params` 不继承**：`Location: /v2/users` 落在基地址上时**不带**原请求的 query——这与 RFC 3986 的解析一致（换路径就换 query），follow-redirects 同样如此。
- **`http_method` 会被写死成解析后的方法**：原始配置里方法可能是 `None`（表示「按默认 GET」），下一跳的配置里它总是 `Some(...)`，这样交出去的配置自己就能说明「这一跳是怎么发的」。

### 凭据什么时候丢

跟随的地址可能不是同一个服务，所以凭据（`Authorization` / `Proxy-Authorization` / `Cookie`，以及 `auth` 字段）在两个条件下丢掉，规则来自 follow-redirects：

1. **协议变了，且新协议不是 https**（也就是降级到明文）；
2. **host 变了，且新 host 不是旧 host 的子域**。

于是两种「看起来还行」的情况会保留凭据：同 host 的 http→https 升级、跳到自己的子域（`api.example.com` → `cdn.api.example.com`）。`example.com.evil.com` 不算子域（后缀相同但换了域）；端口变化算换 host。

host 比较用的是**归一化后的 authority**（`@url.url_authority`：去掉 userinfo、主机名小写、默认端口 `:80` / `:443` 去掉），所以「重定向到显式写了默认端口的同 host 地址」不会白丢一次凭据。

## 交出去的配置与错误

- `Response::config` / `ErrorInfo::config` 是**最后一跳**的配置，所以 `config.url` 就是真正产出响应的那个地址；这也意味着它的 `params` / `base_url` 是空的（已经烘进 `url` 里）。
- 超限的错误码是 `TooManyRedirects`，字符串 `ERR_FR_TOO_MANY_REDIRECTS`（axios 透传的 follow-redirects 错误码）。
- 超限时错误里带着**最后那个 3xx 响应**（用 `read_all_partial` 读，正文可能是半截）：跳了几次、对面给的 `Location` 是什么，都在里面——重定向成环时这是最直接的现场。
- 3xx 的正文在跟随前一概丢弃（`ResponseBody::close()`，等价 follow-redirects 的 `response.destroy()`）；这也是不复用连接的前提下唯一正确的做法，不然每跟一跳就漏一条没人读的连接。

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 默认上限 | 文档写 5，实际由 follow-redirects 兜底 21 | **5**（取文档口径），`Config` 里显式可见 |
| 超限错误里的响应 | 没有（follow-redirects 先把 3xx 响应 destroy 掉） | 有：最后那个 3xx 响应挂在 `error.response()` 上 |
| `response.config` | 最初合并出来的配置（最终 URL 只在 `response.request` 上） | **最后一跳**的配置，`config.url` 是产出响应的地址 |
| `timeout` 覆盖面 | 整条重定向链一个计时器 | 每一跳各算一份（与既有「建连整体 / 每次读取」口径一致），最坏耗时是「上限 × timeout」 |
| 负数上限 | 第一次重定向就报 `ERR_FR_TOO_MANY_REDIRECTS` | 按「不跟随」处理 |
| 相对 `Location` | Node 的 `new URL(location, base)` | 自研 `resolve_url`（RFC 3986 §5.2，含点段归并） |
| 带 scheme 但没有 `//` 的 `Location`（`mailto:x`） | 按带 scheme 的引用处理 | 当成相对路径（判据与 `is_absolute_url`、axios 的 `isAbsoluteURL` 一致：只认 `scheme://`）。正常服务端不会这么写 Location |

`beforeRedirect` 回调、`maxRedirects` 之外的重定向相关开关（例如把某几条头列为敏感头）都不提供，见 README 的「暂不支持」。

## 注意

改这一块时容易漏掉的联动：

1. **改跟随规则或改写规则**：只有 `src/config/redirect.mbt` 一处，用例在 `src/config/redirect_test.mbt`（纯同步，先加用例再改代码）；端到端行为在 `src/redirect_test.mbt`。
2. **改默认上限**：`src/config/default.mbt` 与 `src/client.mbt` 里 `unwrap_or(5)` 的兜底要一起改，`src/redirect_test.mbt` 的「默认 5 跳」用例是有意钉死默认值的。
3. **新增配置字段**：按 `02-config-merge.md` 的流程走（`Config` 字段 → `merge_config` 选策略 → 构建器 → `to_string` 渲染 → 用例）。`max_redirects` 走的是「请求级优先、否则默认」，与 `timeout` 同档。
4. **动 `Config.data` / `Headers` 的删头能力**：`redirect.mbt` 依赖「包内能清空 `data`」这条（同包），删头用的是 `Headers::entries()` + `remove()` 的公开 API，没有为它新增 headers 接口。
5. **动 `url` 包的解析**：`resolve_url` 的结果**一定不含 fragment**（fragment 从不随请求发出），`url_authority` 的归一化是凭据判定的依据，两者都别在别处另写一份。
6. **超时语义**：每跳各一个 `timeout`，改「整条链共用一个时限」要同时看 `05-transport.md` 的超时语义与 `06-sse.md`（SSE 依赖不限时这个前提）。
