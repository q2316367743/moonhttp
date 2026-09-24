# 12 取消请求

对应 axios 的 `cancelToken` / 原生 `AbortSignal`：一次请求可以在**发出之后**被主动中止，
中止后拿到的是一个 `ERR_CANCELED` 错误，而不是网络故障。

与 axios 的关键差别只有形态：本项目只有一个 `CancelToken` 对象（不做
`CancelToken.source()` 那层 token/source 二分），理由见下文。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/config/cancel.mbt` | `CancelToken` 本身：状态机、`attach` / `detach` 机制、`with_cancel_token` 构建器 |
| `src/config/config.mbt` | `cancel_token` 字段（合并策略的分组注释也在这里） |
| `src/config/merge.mbt` | 走策略 2（`prefer_request`）：请求级提供即整体替换实例默认值 |
| `src/transport/cancel.mbt` | **机制的唯一落点**：`with_cancel_scope`（协程级取消）与 `cancelled_failure`（读取前的检查） |
| `src/transport/async_http.mbt` | `send` 把**整跳**（建连、写头、写 body、等响应头）包进取消作用域 |
| `src/transport/stream.mbt` | `ResponseBody` 持有 token：每次读取可取消、读入口先查取消 |
| `src/transport/stream_lifecycle.mbt` | 响应体的构造与释放：`open` 时把「取消即关闭」登记到 token 上、`close()` 时注销（RL-04 拆文件，读语义在 `stream.mbt`） |
| `src/transport/stream_all.mbt` | 读全量的取消检查（`noraise` 的那条路） |
| `src/transport/transport.mbt` | `PreparedRequest::cancel_token` 字段、`TransportError::Cancelled` |
| `src/util/request.mbt` | 把 `Config::cancel_token` 透传进 `PreparedRequest` |
| `src/client.mbt` | 三个入口的**预检查**（`check_cancelled`）、入口文档 |
| `src/http_error.mbt` | `ErrorCode::Cancelled` → `ERR_CANCELED`、`cancelled_error`（文案与 `response` 落点）、`HttpError::is_cancelled` |
| `src/facade.mbt` | 两个流式读失败的出口复用同一条映射；再导出 `CancelToken` |
| `src/config/cancel_test.mbt` | 状态机与合并的同步用例 |
| `src/cancel_test.mbt` | 请求路径的真机用例（等响应头 / 读 body / 重试 / 重定向 / 不粘调用方） |
| `src/cancel_stream_test.mbt` | 流式与上传的真机用例（`stream` / `sse` / 两个进度回调） |

## 对外 API

```moonbit
pub struct CancelToken            // 私有字段：状态 + 一组「取消时要做的事」

pub fn CancelToken::new() -> Self
pub fn CancelToken::cancel(Self, message? : String) -> Unit   // 同步、noraise、幂等、一次性
pub fn CancelToken::is_cancelled(Self) -> Bool
pub fn CancelToken::reason(Self) -> String?                   // 取消时传入的 message

pub fn Config::with_cancel_token(Self, CancelToken) -> Self   // 字段 cancel_token
pub fn HttpError::is_cancelled(Self) -> Bool                  // 等价于 code() is Cancelled
```

```moonbit nocheck
let token = CancelToken::new()
let config = Config::new("/reports/big.csv").with_cancel_token(token)

// 另一条协程里（UI 的停止按钮、看门狗、超时兜底）：
token.cancel(message="用户点了停止")

// 调用方：
client.request(config) catch {
  error if error.is_cancelled() => println("已取消：" + error.message())
  error => println(error.to_string())
}
```

刻意的语义：

- **一次性**：取消之后永远是取消状态，不能复用（与 axios 一致）；一次请求一个 token
  就每次 `CancelToken::new()`。
- **可共享**：同一个 token 可以挂到多个请求上，`cancel` 一次全部生效；也可以放进实例
  默认值（`Client::create(Config::default().with_cancel_token(token))`），表达「这个实例
  发出的请求共用一个取消信号」。
- **取消晚一步也算数**：取消发生之后才发出的请求会**立刻失败**，不会「取消晚了一步就
  照常发出去」（机制见下面的「两条兜底」）。
- **`cancel` 是同步函数且不抛错**：所以可以从任何地方调用——包括 `noraise` 的进度回调里。
- **取消理由落成错误文案**：`cancel(message="…")` 的 message 就是
  `HttpError::message()`；没给就用默认文案「请求已取消」。文案只在 `src/http_error.mbt`
  一处（token 自己不编文案）。

## 机制：为什么是协程级取消，而不是查标志位

`src/transport/cancel.mbt` 的 `with_cancel_scope` 是全部机制的唯一实现：

```
token 有值 ——> with_task_group ─┬─ 子任务：跑真正的 I/O（send / read）
                                ├─ token.attach(() => task.cancel())   ← 取消时中断它
                                └─ task.wait() → TaskCancelled → TransportError::Cancelled
token 为 None → 直接跑，不建任务组（零额外开销）
```

为什么不是「每次读写前看一眼 token 有没有取消」：

- 检查只在**执行到检查点时**有效。请求卡在「等首字节」「建连中」时根本没有下一个检查点，
  而那恰恰是最需要取消的场景（测试用例 `cancel interrupts a request waiting for the
  response headers` 断言 3 秒的停顿里不到 1 秒就结束了）。
- 协程级取消的落点是**挂起点**（`moonbitlang/async` 的 README：`task cancellation can only
  happen when a task is in suspended state`），挂起中的 socket 动作会被真的中断。
  这不是新机制——**`@async.with_timeout` 用的就是同一套**（`with_timeout` = 起一个计时子
  任务，到点给自己人发取消），所以「超时能打断挂起的 I/O」这件事在本项目早有实证。

一条容易忽略但很值钱的性质：**被取消的是库自己 spawn 的子任务，不是调用方的协程**。
取消是「粘在任务上的状态」，如果直接取消调用方的协程，调用方之后所有异步操作都会被立刻
取消。放在子任务里就没有这个问题——调用方拿到的只是一个普通错误，可以接着发下一个请求
（用例 `a cancelled request does not stick to the calling coroutine` 钉着它）。

## 检查与中断落在哪

| 时机 | 落点 | 行为 |
|---|---|---|
| 请求进入管线**之前** | `Client::request` / `open_stream` 里的 `check_cancelled`（合并配置之后、请求拦截器之前） | 立刻抛 `ERR_CANCELED`：**不发任何 I/O，也不跑请求拦截器**（拦截器可能带副作用） |
| 每一跳发送**之中** | `AsyncHttpTransport::send` 的取消作用域包住 `send_head` | 打断挂起的建连 / 写头 / 写 body / 等响应头 |
| 两次 I/O **之间** | `attach` 到已取消的 token 会立刻触发那条登记 | 补上窗口期：重定向的两跳之间、两次响应体读取之间都是真实的时间窗 |
| 响应体读取**之中** | `read_or_fail` 的取消作用域（`read_some` / `read_until` / `read_all` / SSE 都经过它） | 打断挂起的读，抛 `TransportError::Cancelled` |
| 取消已经发生**之后** | 读入口先查 `cancelled_failure`；`ResponseBody` 自己挂在 token 上的「取消即 `close()`」 | 报取消而**不是**退化成 EOF；同时立刻释放连接（调用方取消后不再读也不漏连接） |

覆盖范围：三个入口都覆盖。`request` 是整条链（重定向 + 读全量），`stream` / `sse`
既覆盖建连与取响应头、也覆盖之后的每一次读取——所以「取消一条已经在消费的 SSE 长连」
是真的可用，不是只能取消握手。

## 取消长什么样

```
TransportError::Cancelled  →  ErrorCode::Cancelled  →  "ERR_CANCELED"
```

- `ErrorCode::Cancelled` 是第 8 类错误码，对应 axios 的 `AxiosError.ERR_CANCELED`；
  与超时（`ECONNABORTED`）**分开**，调用方才能把「用户主动中止」和「超时兜底」区别对待
  ——前者通常不该重试、也不该报给用户。
- `TransportError::Cancelled` 不带文案：取消理由在**合并后的配置**上（`cancel_token`），
  由 `src/http_error.mbt` 的 `cancelled_error` 统一翻译。传输层只表达「这是取消，不是网络故障」。
- **错误里带已经收到的响应**：取消发生在响应头到手之后时，状态行、响应头与已读到的字节
  都挂在 `HttpError::response()` 上——与超时、断连的口径一致（`docs/04-errors.md` 的
  「失败时带上已经收到的响应」那条规则）。请求还没发出去就取消时是 `None`。
  这一点与 axios 不同：axios 的 `CanceledError` 不带响应。

## 与其它能力的关系

**与 `timeout`**：两者是独立的中断手段，先到的说了算。取消作用域**在超时的错误收敛之外**，
所以取消比超时先到时报的是取消而不是 `ECONNABORTED`（用例 `cancel reports cancelled rather
than a timeout when it lands first` 钉着）。`timeout` 的语义没有因为取消改变：仍然是「建连
到响应头整体一个时限 + 响应体每次读取一个时限」。

**与拦截器**：取消错误**照常流经响应侧错误处理器**（与 axios 一致，也符合本项目「所有失败
过同一个漏斗」的口径），不做特判。给重试写法的建议很直接：重试配方是拿 `error.config()`
再调一次 `Client::request`，而那次调用会走**预检查**——token 已经取消，于是重试**立刻失败、
不产生第二次请求**，不会把无脑重试变成一串真实 I/O（用例 `a retry after cancel fails fast
without another request` 钉着）。想在重试前判断，看 `error.is_cancelled()`。

**与进度回调**：回调跑在可被取消的子任务里（上传的回调在发送子任务、下载的回调在读全量子
任务），所以在回调里调 `token.cancel(...)` **立刻对这一段生效**——下一块不会再写 / 不会再读。
这正是给 `noraise` 回调配上同步 `cancel` 的意义：回调拿不到任何返回信号，但随手能喊停。
两条用例（`cancelling from the upload/download progress callback stops the …`）分别钉住上传
与下载。

**与 `MockTransport`**：Mock **不模拟取消中断**——它是同步返回的，没有挂起点可中断。这与
「Mock 不上报上传进度」（`docs/10-progress.md`）是同一种诚实声明。Mock 上仍然成立的是
**预检查**那一条（「已取消的 token 让请求什么都不做」，用例在 `src/cancel_test.mbt`）；
要验证「打断挂起的 I/O」必须起真实连接，那批用例都在真机 server 上跑。

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 形态 | `CancelToken` + `CancelToken.source()` 双层（或 `AbortController` + `signal`） | 单对象 `CancelToken`（`cancel` / `is_cancelled` / `reason`） |
| 判定取消 | `axios.isCancel(err)`（看 `__CANCEL__` 标记） | `HttpError::is_cancelled()`（看 `code()`） |
| 取消错误的上下文 | `CanceledError` 不带 `response` | 带上**已经收到的响应**（半截正文也在），与超时 / 断连一致 |
| 中断范围 | 取决于适配器（浏览器 XHR、node http） | 建连、写请求、等响应头、读响应体、SSE 事件读取都可中断 |
| `signal` / `AbortController` | 支持 | 没有对应物（本项目不需要跨语言的对象协议，一个 handle 就够） |
| 取消原因 | `CanceledError.message` = `cancel()` 的实参，默认 `"canceled"` | 相同机制，默认文案是中文「请求已取消」 |

## 注意事项（改动时）

1. **机制只在一处**：打断动作（`with_cancel_scope`）与读取前的检查（`cancelled_failure`）
   都在 `src/transport/cancel.mbt`。新增会挂起的 I/O 路径时，把它包进取消作用域——
   对底层库的依赖仍然只允许出现在 `transport` 包里（`docs/README.md` 的同步清单第 4 条）。
2. **不能把取消做成「错误里的一个变体就完事」**：取消在协程模型里是**信号**，`catch` 抓不住
   它（`defer` / `errdefer` 会跑）。所以 `with_cancel_scope` 必须自己 `task.wait()` 并把
   `TaskCancelled` 翻译成 `TransportError::Cancelled`；指望上层 catch 是抓不到的。
3. **`attach` 到已取消的 token 会立刻触发**（`src/config/cancel.mbt`）。这不是容错，是语义：
   `cancel` 只通知得到当时登记过的句柄，晚登记的必须自己立刻断。删掉它就会留下「重定向第
   二跳照常发出去」这种漏洞。
4. **一次性状态**：token 取消后不可复用，`cancel` 幂等。别加「重置」——那会让「已取消」这个
   判断在并发路径上失去意义。
5. **同步段不可中断**：取消只在挂起点生效，一段纯计算（超大的 JSON 解析、回调里的长循环）
   不会被打断。要让它可中断，得在中间插 `@async.pause()`。
6. **清理沿用既有路径**：`send_head` 的 `errdefer client.close()`、`read_some` 的
   `errdefer self.close()`、`read_all_partial` 尾部的 `self.close()` 在取消时照样跑
   （README：取消信号会触发 `defer` / `errdefer`），所以没有新增清理代码。改这些清理路径时
   别忘了取消路径也在依赖它们。
7. **流式的取消不能退化成 EOF**：读入口先查 `cancelled_failure` 就是为了这个。少了它，
   `while stream.read_some() is Some(_)` 会安静收场、`next_event()` 会返回 `None`，调用方
   会以为对端正常结束。
8. **开销**：设了 token 之后，每一跳发送与每一次读取各多一层任务组；没设 token 时不建任务组、
   零开销。这与「设了 `timeout` 时每次读取本来就包一层 `with_timeout`」同量级。

## 不做的事

- **token 复用 / 重置**：一次性的（与 axios 一致）。
- **父子 token 链**（一个 token 取消一组子 token）：现在的做法是共享同一个 token。
- **把 `timeout` 改写成 token**：二者语义不同（超时是「等太久了」，取消是「不要了」），
  合并成一层只会让错误码与文案都要多一层特判。
- **`MockTransport` 上报取消**：见上文「与 `MockTransport`」。
- **取消重定向的中间处理**：重定向的两跳之间没有用户回调，取消在这一层的落点就是 `attach`
  那条兜底。
