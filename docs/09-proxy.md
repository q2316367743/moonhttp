# 09 代理

对应 axios 的 `proxy`：**配了 `Config.proxy` 之后，请求全部经代理服务器转发**，支持到代理的基础认证（`Proxy-Authorization`）与 HTTPS 代理。

一句话概括实现：**配置形状在 `config` 包，凭据落点在 `util` 包，隧道在 `transport` 包**——真正的 `CONNECT` 隧道由底层 `moonbitlang/async` 完成，本模块只负责把「连到哪儿、带什么凭据」翻译成它要的形状。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/config/proxy.mbt` | `Proxy` / `ProxyProtocol` 类型、`Config::with_proxy` 构建器、`Proxy::is_usable` 判定、`Proxy::to_string`（密码脱敏） |
| `src/config/merge.mbt` | `merge_proxy`：策略 3 的逐字段深合并（内层 `auth` 递归交回 `merge_auth`） |
| `src/config/render.mbt` | `Config::to_string` 里的 `proxy` 臂 |
| `src/util/request.mbt` | `build_prepared_request`：拼出代理地址、决定 `Proxy-Authorization` 的取值，并把它从目标请求头里取走 |
| `src/transport/transport.mbt` | `ProxyEndpoint`（`url` + `authorization`）与 `PreparedRequest::proxy` 字段 |
| `src/transport/async_http.mbt` | `open_proxy`：建一个干净的代理客户端交给底层；`ProxyError` → `TransportError::Network` 的翻译 |
| `src/client.mbt` | `prepare_request`：代理配置缺 host 时报 `ERR_INVALID_URL`（与「缺 url」分开报） |
| `src/config/proxy_test.mbt` / `src/config/merge_wbtest.mbt` | 构建器 / 判定 / 渲染 / 合并的同步用例 |
| `src/proxy_test.mbt` | 拼装契约（不走网络）与本机 CONNECT 代理的端到端用例（隧道、407、握手超时、缺 host） |

## 配置形状

```moonbit
Config::default().with_proxy("127.0.0.1", port=9000)
Config::default().with_proxy(
  "proxy.corp", port=8443, protocol=ProxyProtocol::Https,
  username="mikeymike", password="rapunz3l",
)
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `host` | **是** | 代理服务器主机名或 IP |
| `port` | 否 | 缺省由协议决定（http 80 / https 443），由底层补；本模块**不写**这个默认端口 |
| `protocol` | 否 | `ProxyProtocol::Http`（缺省）/ `Https`；`Https` 指**到代理本身**走 TLS，与「目标是 https」是两件事 |
| `auth` | 否 | HTTP Basic 凭据，复用 `Auth`；渲染时密码脱敏成 `<redacted>` |

字段都是 `Option`（`None` = 未提供），所以合并是**逐字段深合并**：实例默认值给地址、请求级只给凭据时，合并结果两者都在（与 `auth` 同一档，用例见 `merge_wbtest.mbt` 的 `proxy merges field by field`）。

**只有 `host` 是必填的**，而且「给了 `proxy` 却没给 host」是**错误**、不是「没配代理」：`Proxy::is_usable` 返回 `false`，`build_prepared_request` 返回 `None`，根包报 `ERR_INVALID_URL`（文案点名是代理的问题）。做成静默直连的话，本该走代理的请求会从别的路出去——对一个「要过代理」的配置来说，这是最危险的失败方式。

## 数据怎么流动

```
Config.proxy            （配置：协议 / host / port / auth）
  ↓ build_prepared_request（util）
PreparedRequest.proxy = ProxyEndpoint { url: "http://127.0.0.1:9000", authorization: Some("Basic ...") }
  ↓ Transport::send（transport）
@http.Client::Client(目标地址, proxy=@http.Client::Client(代理地址, headers={Proxy-Authorization}))
  ↓ 底层
CONNECT 目标host:port  → 200 → 进入隧道 → 在隧道里发真正的请求（https 目标再叠一层 TLS）
```

分层的意义：`ProxyEndpoint` 已经是**解析完的最小形态**（协议名与端口写进了 `url`，凭据编码成了可直接落头的字符串），传输层因此不认识 `ProxyProtocol` 这类配置枚举，也不需要知道 Basic 认证怎么编码——与 `PreparedRequest`「不含任何配置语义」的口径一致。

## 凭据落在哪个请求上

**代理凭据只出现在 CONNECT 上，不会发给目标服务器**。`Proxy-Authorization` 的取值按 axios 的规则决定：

| 情况 | CONNECT 带的 `Proxy-Authorization` | 目标请求头里的 `Proxy-Authorization` |
|---|---|---|
| 有 `proxy.auth` | `Basic base64(username:password)`，**覆写**用户自定义的同名头 | 取走（不发） |
| 只有用户自定义的头 | 用户自己写的那个值 | 取走（不发） |
| 都没有 | 无（匿名代理） | 无 |
| 没配代理 | ——（没有 CONNECT） | 原样保留（与加代理之前的行为一致） |

「取走」这一步是实现的必然：代理是**另一个**请求（CONNECT），把头留在目标请求上只会让代理凭据穿过隧道泄漏给源站。`redirect.mbt` 也把 `Proxy-Authorization` 当敏感头对待（跨 host 时丢弃），两边口径一致。

用户名或密码只给了一个时，另一半按空串参与编码——与 `with_auth` 一致。

## 网络行为

| 行为 | 说明 |
|---|---|
| 连接方式 | 底层对**所有**目标都用 `CONNECT` 隧道，**http 目标也走 CONNECT**（不是「把完整地址发进请求行」那种经典 HTTP 代理写法）。所以代理服务器必须支持 `CONNECT`，只支持 GET/POST 转发的简易代理不行 |
| 隧道数量 | 每个请求各建一条（重定向时**每一跳**各建一条），与本模块「不复用连接」的现状一致 |
| https 目标 | 隧道之上再做一次目标的 TLS；两次 TLS 互相独立（到代理的那次由 `protocol` 决定，到目标的那次始终由目标地址决定） |
| 超时 | CONNECT 握手在 `@async.with_timeout` 包住的那一段里，所以**握手也受 `timeout` 约束**（用例：`connect handshake respects the timeout`） |
| 重定向 | 代理设置随 `next_redirect` 的记录展开原样保留（它是「怎么出去」，不是凭据），跨 host 也不丢 |
| 目标平台 | 底层的代理能力按 native 目标交付（`resolve_host` 带 `#cfg(any(target="native", target="wasm"))`，JS 目标上 `proxy` 参数明确不支持）。本模块 `preferred_target = "native"` |

## 错误分类

| 情况 | 结果 |
|---|---|
| CONNECT 的响应不是 2xx（最常见是 `407` 需要认证） | `TransportError::Network`，文案是 `代理拒绝建立隧道：HTTP <状态码> <原因短语>` → 对外 `ERR_NETWORK`（`error.message()` 里能看到状态码）。这时响应头还没到手，所以错误里**没有** `response` |
| 连不上代理（端口没人听、DNS 失败） | `Network`（底层错误原文照旧保留） |
| CONNECT 握手超时 | `Timeout`（`ECONNABORTED`） |
| 代理配置缺 host | `InvalidUrl`（`ERR_INVALID_URL`），文案点名是代理的问题；请求根本没发出去 |

没有为代理单开 `TransportError` 或 `ErrorCode` 变体：代理失败的处置方式与其它网络失败相同（换代理、加凭据、重试），多一个分类只会让调用方多写一个分支。CONNECT 被拒时错误里也不带响应——`ProxyError` 携带的那个 `Response` 属于代理而不是源站，混进错误里会让人误以为「目标服务器回了 407」。

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 环境变量 | 默认读 `http_proxy` / `https_proxy`，`no_proxy` 列例外域 | **不读**。环境变量会让「同一份代码在不同机器上走向不同的出口」，配置即事实；要按环境切代理请显式传 `with_proxy(...)` |
| 按请求关闭代理 | `proxy: false` 显式关掉（含环境变量提供的代理） | 不提供。需要绕开实例默认代理时另建一个不带代理的实例（`Config` 的 `None` 语义是「未提供、只能回退」，表达不了「显式关掉」） |
| http 目标 | 经典代理写法：请求行里放完整地址，`Proxy-Authorization` 落在那个请求上 | 统一走 CONNECT 隧道（底层实现如此），凭据落在 CONNECT 上 |
| 用户自定义的 `Proxy-Authorization` | 隧道模式下会随目标请求一起发出去 | 有代理时取走、只用于 CONNECT；没代理时不碰（见上一节） |
| 代理协议 | `protocol` 字符串（`http` / `https`） | `ProxyProtocol` 枚举（拼错是编译错误） |
| SOCKS | 不支持 | 不支持（只做 HTTP 隧道） |

## 注意

改这一块时容易漏掉的联动：

1. **新增代理字段**：`src/config/proxy.mbt` 加字段 → `merge_proxy` 里选一档（漏了是编译错误）→ `Config::with_proxy` 收集 → `Proxy::to_string` 渲染 → 需要的话在 `proxy_endpoint`（`src/util/request.mbt`）里用上 → 更新 `02-config-merge.md` 的字段表与本文件。
2. **`ProxyEndpoint` 的字段语义**：它出现在 `PreparedRequest`（公开签名）里，改动要同步 `05-transport.md`；它是「已经解析完的最小形态」，别把配置语义（协议枚举、默认端口、用户名密码）塞回来。
3. **凭据规则**：只有 `src/util/request.mbt` 一处实现（含「从目标头里取走」那一步），用例在 `src/proxy_test.mbt` 的前三条；别在传输层再补一次 `Proxy-Authorization`。
4. **`PreparedRequest::proxy` 为 `None` 时**：必须与「加代理之前」完全等价（不建代理客户端、不发 CONNECT），否则直连路径会被悄悄改变。
5. **代理客户端的生命周期**：底层的 `Client::Client` 会**接管**传入的代理客户端（进入隧道后调用方不能再碰），所以每个请求都要新建一个，不能缓存复用。已知微瑕：目标地址非法（端口越界）时底层在接管前就抛错，那条到代理的连接不会被关掉——只出现在「地址本来就发不出去」的路径上。
6. **改超时语义**：CONNECT 握手依赖「建连那一段整体受 `timeout` 约束」，见 `05-transport.md`。
