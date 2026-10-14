# 21 · 连接池（连接复用）

> 状态：**已落地**（2026-10-14）。第 1 期「每请求一条连接」的契约与分期见 `17-http-protocol.md`，本文档记录第 2 期的设计与实现。改动本主题前先读这里。

## 0 · 一句话

自研传输层的连接在响应结束后不再一律关闭：读满且服务端允许复用的连接按「这条连接服务谁」分桶入池，下一个同目标请求直接取用，省掉重复的 TCP / TLS / CONNECT 握手。

## 1 · 契约（全部继承自 docs/17 口径 4，本期只拍板了两条）

| 契约 | 落点 |
|---|---|
| **响应体未消费完不回池** | `BodyReader::is_reusable`（体读满才为真）+ 释放通道的 `Finished` 语义 |
| **取消 = 毒化连接** | 取消触发的释放恒走 `Abandoned` → 关连接（`register_cancel_close`） |
| **按 `(scheme, host, port, tls, proxy)` 分桶** | `pool_key`（代理凭据入键，键含凭据**绝不打印**） |
| **每 host 上限** | 本期拍板：**只限空闲数量**（桶满直接关，不排队、不限并发）；「并发上限 + 等待队列」是后续增强（需要 `@async.Semaphore`） |
| **空闲超时** | 惰性过期：不起后台定时器，取用时按 `idle_since` 判断，过期就地关闭 |
| **取用时坏连接重试一次** | `StaleConnection` 信号 + `send_head` 的重试资格裁决（见 §4） |
| **CONNECT 隧道入池** | 隧道在 dial 内建立，池以完整坐标为键，隧道连接与直连无差别入池 |

## 2 · 设计

### 2.1 池本体（`src/httpconn/pool.mbt`）

```moonbit
priv struct ConnectionPool {
  buckets : Map[String, Array[PooledConn]]   // 键 = pool_key，值 = LIFO 栈
  max_idle_per_host : Int                    // 0 = 禁池（行为退回 phase 1）
  idle_timeout_ms : Int                      // <= 0 = 不过期
}
```

- **LIFO**：刚还回去的连接最可能还热着（TLS 会话票据、TCP 拥塞窗口）。
- **无锁**：`moonbitlang/async` 是单线程协作式调度（其 README 明言），`acquire` / `release` 全程没有 await 点，协程不会在池操作半途被打断——普通可变结构就是安全的。需要「等待连接」语义时才引入锁 / 信号量。
- **过期**：`acquire` 弹栈路上顺手清掉过期连接，空桶从 Map 里删掉（host 数量只增不减的问题不存在）。
- **禁池**（`max_idle_per_host = 0`）：`release` 一律关闭，请求头恢复 `Connection: close`——完整退回 phase 1 行为，也是测试与「我就要每请求一条连接」场景的出口。

### 2.2 复用判定：两层合取

**服务端允不允许**（响应头层面，`build_raw_response` 里一次算好）：

```
server_allows = 分帧 ≠ UntilClose          （体以关闭收尾，天然不可复用）
             && 请求方没自己声明 close       （用户显式 Connection: close 逐请求禁复用）
             && connection_reusable(版本, Connection 头)
```

`connection_reusable`（`src/httpproto/keepalive.mbt`，纯函数）：HTTP/1.1 默认持久、`close` token 才关；HTTP/1.0 必须显式 `keep-alive` 确认；`close` 与 `keep-alive` 并存的矛盾声明按关闭处理；token 允许出现在逗号列表的任意位置、任意一条同名头里。

**体读没读满**（读取状态，`BodyReader` 自持）：`mode` 到 `Done | Empty` 且 `truncated` 未置位。`truncated` 修掉了 phase 1 的地雷——定长体被截断时旧实现也置 `Done`，分不清「读完」与「被断」；现在 EOF 交出语义不变（截断的正文仍留给上层判断），只是多记一个「连接已死」。

两者在释放回调里合取：`is_reusable() = server_allows && !truncated && mode is (Done | Empty)`。

### 2.3 释放的双通道（`src/transport/stream_lifecycle.mbt`）

响应体释放从单回调升级为带结局的 dispose：

```moonbit
pub(all) enum BodyEnd { Finished; Abandoned }
pub fn ResponseBody::open_wire_dispose(reader, dispose : (BodyEnd) -> Unit, ...)
```

- **`Finished`**：读取正常走到 EOF。三个触发点：`read_some` 的 EOF 分支、`read_until` 的 EOF 分支、`read_all_partial` 无失败收尾。池凭它 + `is_reusable` 决定还池还是关闭。
- **`Abandoned`**：`ResponseBody::close()` 的全部调用方——errdefer（读失败）、取消登记、显式 `close`、重定向弃 3xx 体、`StreamResponse::close` / `SseStream::close`。一律关连接。
- 释放幂等靠「立刻置 `Closed`」：第二次 dispose 不会再触发回调（池最怕重复回收）。
- `open_wire`（单回调旧签名）保留为兼容入口：包装成「无论结局都关连接」。

### 2.4 取用与坏连接重试一次（`src/httpconn/transport.mbt`）

`send_head` 的骨架：

```
key = pool_key(target, proxy)
reused = pool.acquire(key)            // None = 该拨号了
run(conn) = { errdefer conn.close(); 写头写体 → 读响应头 → build_raw_response }
send_once = match reused {
  Some(conn) if 请求体可回卷 => try run(conn) catch { StaleConnection → 换新连接 run 一次 }
  Some(conn)                 => run(conn)
  None                       => run(dial())
}
整体套原有的 with_timeout（重试与首跳共享同一预算）
```

**坏连接信号**：`priv suberror StaleConnection`，只在「一个响应字节都没到」的三个时刻抛——写请求头失败、写请求体失败、首个状态行干净 EOF **或读取失败**（对端 RST 与干净 EOF 同罪）。从这里起响应已开始的失败（1xx 之后、头块中途）仍报 `Malformed`，不可重试。

**重试资格**：连接来自池 **且** 请求体可回卷（无体或缓冲体）。流式体读过的字节拿不回来，直接报错（`StaleConnection` 统一映射 `Network`）。

**有意的错误分类变化**：新建连接在响应开始前死掉（写失败 / 状态行前 EOF），phase 1 报 `Malformed`（ERR_BAD_RESPONSE），现在报 `Network`（ERR_NETWORK）——对端断开是网络失败，ERR_BAD_RESPONSE 应该留给「真的收到了坏字节」。`docs/18` 的行为对照已同步。

## 3 · 线上行为

| 场景 | 请求侧 | 响应结束后 |
|---|---|---|
| 池启用（默认） | 不发 `Connection` 头（1.1 默认持久，对齐 Go / Python / Node） | 读满且服务端允许 → 入池；否则关闭 |
| 用户显式 `Connection: close` | 原样落线（`set_if_absent` 用户赢） | 不回池（读完即关） |
| 禁池（`max_idle_per_host = 0`） | 恢复 `Connection: close` | 一律关闭 |

请求头表的完整契约见 `18-httpconn-transport.md`。

## 4 · 配置面

- **不进 `Config`**：池参数是实例级 / 传输级的运行时状态，与 `cookie_jar`、signal 同一条先例（`client.mbt` 的注释）。走 `HttpConnTransport::new(max_idle_per_host?, idle_timeout_ms?)`，经 `Client::new(transport=...)` 注入；`Client::create` 派生的实例共享同一个池（transport 引用共享）。
- **缺省值**：`max_idle_per_host = 4`（urllib3 的 pool_maxsize 同款）、`idle_timeout_ms = 30_000`（Go 是 90s，取短对服务端友好、少踩重试路径）。
- **门面**：根包 `pub using @httpconn {type HttpConnTransport}` 再导出，调池参数不需要直接依赖子包。
- **逐请求出口**：用户显式 `Connection: close` 头。

## 5 · docs/17 五状态机的落地映射

`Connecting → Idle → Busy → Draining → Closed` 不落成显式状态字段，落在**所有权**上：

| 状态 | 落点 |
|---|---|
| Connecting | `dial` 进行中（连接尚未入池，请求任务持有） |
| Idle | 在池（`PooledConn`，带 `idle_since`） |
| Busy | 请求任务持有（`send_head` 到响应体释放之间） |
| Closed | 已关闭（各毒化出口 / 过期 / 超额） |
| Draining | **不设**：phase 1 的释放是同步 `close()`，不存在「待收尾」的悬挂态；「读完但不可复用」在 dispose 里当场关闭 |

单线程协作式调度下，所有权即互斥——一条连接同一时刻只在一个状态里，无需状态字段与锁。

## 6 · 已知限制与风险

1. **双发窗口**：复用连接写失败后的重试，理论上可能重放一个「服务端已收到并处理但响应没回来」的请求（对非幂等请求是双发）。这是 Go `http.Transport` 同款权衡：只在「响应一个字节都没到」时重试、且只重试一次。缓解手段是业务侧对非幂等请求显式带 `Connection: close`。
2. **上传进度与缓冲体会在重试时重放**：进度回调可能看到第二次从 0 开始的报告。罕见路径，不做抑制。
3. **病态服务端**在两个响应之间主动推字节：会留在连接缓冲里污染下一个响应的解析（解析报 `Malformed`）。RFC 语义下服务端无此权利，不做防御。
4. **不读完也不 `close()` 的连接悬空**：与 phase 1 相同的既有泄漏（MoonBit 无析构器），连接既不回池也不关闭，`docs/05` 的警告原文有效。
5. **空闲连接的死亡由重试兜底**：服务端随时可以关掉池里的连接，我们不做 keep-alive 探测（不发探测字节），第一次取用失败即换新连接——这正是「重试一次」存在的意义。
6. **SOCKS5** 未落地（`docs/17` 口径 3 的下一提交）；`pool_key` 已把代理坐标入键，落地后隧道连接自然入池。

## 7 · 关键文件

| 文件 | 职责 |
|---|---|
| `src/httpconn/pool.mbt` | 池本体：分桶 / LIFO / 惰性过期 / 上限 / 禁池；`pool_key` |
| `src/httpconn/transport.mbt` | `send_head` 取用 + 重试骨架；`build_raw_response` 的复用判定与 dispose 接线 |
| `src/httpconn/response_read.mbt` | `StaleConnection` 定义与三处抛点（首状态行的 EOF / 读失败） |
| `src/httpconn/request_write.mbt` | Connection 头开关（`declare_close`）；写失败的坏连接信号 |
| `src/httpconn/body_reader.mbt` | `truncated` / `server_allows` / `is_reusable` |
| `src/httpproto/keepalive.mbt` | `connection_reusable` / `declares_close` 纯函数 |
| `src/transport/stream_lifecycle.mbt` | `BodyEnd`、`open_wire_dispose`、`close`（Abandoned）与 `close_as_finished` |
| `src/transport/stream.mbt` / `stream_all.mbt` | EOF 触发点改走 `Finished` |
| `src/main/transport/pool.mbt` | 示例段 12：线上证据（头有无 / 禁池 / 显式 close） |

## 8 · 测试地图

- `src/httpproto/keepalive_test.mbt`：版本 × Connection 头判定矩阵（8 条）。
- `src/transport/stream_dispose_test.mbt`：dispose 双通道语义（EOF→Finished、放弃/失败/取消→Abandoned、幂等）。
- `src/httpconn/pool_real_test.mbt` + `pool_retry_real_test.mbt`（真连接，夹具在 `pool_server_fixture_test.mbt`）：单连接两次请求、服务端 close、HTTP/1.0、截断毒化、半途放弃、取消毒化、坏连接透明重试、流式体不重试、空闲过期、上限关闭、禁池、用户显式 close（12 条，断言全取服务端视角）。
- 白盒：`request_write_wbtest.mbt` 钉 Connection 头开关契约。

## 9 · 改动时的同步

改池行为时同步：本文档、`docs/17`（分期表）、`docs/18`（请求头表与行为对照）、`docs/05`（`ResponseBody` 契约）、`docs/13`（示例段）、`README.mbt.md`（能力表与快捷说明）。测试新增遵循 §8 的分层：纯逻辑进 httpproto、释放语义进 transport、真连接进 httpconn 的 `_test` 夹具。
