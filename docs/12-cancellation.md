# 12 取消请求

对应 axios 的 `signal` / 平台的 `AbortController`：一次请求可以在**发出之后**被主动中止，
中止后拿到的是一个 `ERR_CANCELED` 错误，而不是网络故障。

形态与平台原生一致：`AbortController` 是**发起方**（谁持有它谁才有权叫停），随请求走的是它的
`AbortSignal`。与 axios 有一处**刻意的不同**：信号只能作为三个入口的 `signal?` 参数按请求传，
**不能放进实例默认值**（`Config` 里根本没有这个字段）。理由见下面的「信号为什么不是配置字段」。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/abort/abort.mbt` | `AbortController` / `AbortSignal` / `AbortError`：状态机、`attach` / `detach` 登记机制 |
| `src/abort/README.mbt.md` | 包级 API 清单与用法 |
| `src/client.mbt` | **信号的唯一入口**：三个入口的 `signal?` 参数、预检查 `check_cancelled`（`throw_if_aborted` + `AbortError` 归一）、往 `dispatch_request` / `open_stream` / `send_following_redirects` 逐层透传 |
| `src/shortcuts.mbt` | 七个快捷方法的 `signal?` 参数（原样透传给 `request`） |
| `src/util/request.mbt` | `build_prepared_request(config, signal?)`：把信号搬进 `PreparedRequest::signal` |
| `src/transport/abort.mbt` | **机制的唯一落点**：`with_abort_scope`（协程级取消，进入时先查 `aborted()`）与 `aborted_failure`（读取前的检查） |
| `src/transport/async_http.mbt` | `send` 把**整跳**（建连、写头、写 body、等响应头）包进取消作用域 |
| `src/transport/stream.mbt` | `ResponseBody` 持有信号：每次读取可取消、读入口先查取消 |
| `src/transport/stream_lifecycle.mbt` | 响应体的构造与释放：`open` 先查 `aborted()`（已取消就立刻关连接），否则登记「取消即关闭」；`close()` 时注销 |
| `src/transport/stream_all.mbt` | 读全量的取消检查（`noraise` 的那条路） |
| `src/transport/transport.mbt` | `PreparedRequest::signal` 字段、`TransportError::Cancelled(reason)` |
| `src/http_error.mbt` | `ErrorCode::Cancelled` → `ERR_CANCELED`、`cancelled_error` / `abort_error`（文案与 `response` 落点）、`HttpError::is_cancelled` |
| `src/facade.mbt` | 两个流式读失败的出口复用同一条映射；再导出两个类型 |
| `src/abort/abort_test.mbt` | 状态机与登记机制的同步用例 |
| `src/transport/abort_wbtest.mbt` | 「进来就已取消」这条兜底与理由载荷的白盒用例 |
| `src/cancel_test.mbt` | 请求路径的真机用例（等响应头 / 读 body / 重试 / 重定向 / 不粘调用方） |
| `src/cancel_stream_test.mbt` | 流式与上传的真机用例（`stream` / `sse` / 两个进度回调） |

## 对外 API

```moonbit
// 三个入口（七个快捷方法同形：get / post / put / delete / patch / head / options）
pub async fn Client::request(Self, Config, signal? : AbortSignal) -> Response raise HttpError
pub async fn Client::stream (Self, Config, signal? : AbortSignal) -> StreamResponse raise HttpError
pub async fn Client::sse    (Self, Config, signal? : AbortSignal) -> SseStream raise HttpError

// 取消原语（定义在 `abort` 包，根包再导出）
pub struct AbortController                                    // 发起方：私有字段（它持有的信号）
pub struct AbortSignal                                        // 观察口：私有字段（状态 + 一组登记）

pub fn AbortController::new() -> Self
pub fn AbortController::signal(Self) -> AbortSignal
pub fn AbortController::abort(Self, reason? : String) -> Unit  // 同步、noraise、幂等、一次性

pub fn AbortSignal::abort(reason? : String) -> Self           // 静态：出生即已取消
pub fn AbortSignal::aborted(Self) -> Bool
pub fn AbortSignal::reason(Self) -> String?
pub fn AbortSignal::throw_if_aborted(Self) -> Unit raise AbortError
pub fn AbortSignal::attach(Self, () -> Unit noraise) -> Int    // 内部机制（见下）
pub fn AbortSignal::detach(Self, Int) -> Unit                  // 内部机制

pub(all) suberror AbortError { Aborted(String?) }              // 载荷 = signal.reason()

pub fn HttpError::is_cancelled(Self) -> Bool                   // 等价于 code() is Cancelled
```

```moonbit nocheck
let controller = AbortController::new()
let config = Config::new("/reports/big.csv")

@async.with_task_group(group => {
  let running = group.spawn(() => {
    api.request(config, signal=controller.signal()) catch {
      error if error.is_cancelled() => println("已取消：" + error.message())
    }
  })
  @async.sleep(2_000)
  controller.abort(reason="用户点了停止")
  running.wait()
})
```

刻意的语义（与平台一致）：

- **一次性**：取消之后永远是取消状态，不能复用；需要「一次请求一个信号」就每次
  `AbortController::new()`。
- **可共享，但只能按请求显式共享**：同一个信号可以挂在任意多次调用上
  （`request(c1, signal=s)`、`request(c2, signal=s)`），`abort` 一次全部生效；它**不会**
  被实例默认值继承——「一次请求一个信号」在类型上就成立。
- **取消晚一步也算数**：取消发生之后才用同一个信号发起的请求会**立刻失败**，不会「取消晚了
  一步就照常发出去」（机制见下面的「两条兜底」）。
- **发起方与观察方分开**：拿到信号的一方只能观察（`aborted` / `reason`），叫停要拿控制器。
  这条分工是换成这套 API 的主要收益——「误调用取消」在类型上就写不出来，而 `CancelToken`
  只有一个对象，谁拿到都能取消。
- **`abort` 是同步函数且不抛错**：所以可以从任何地方调用——包括 `noraise` 的进度回调里。
- **取消理由落成错误文案**：`abort(reason="…")` 的 reason 就是 `HttpError::message()`；
  没给就用默认文案「请求已取消」。文案只在 `src/http_error.mbt` 一处（信号自己不编文案）。

## 信号为什么不是配置字段

axios 允许把 `signal` 放进实例默认值（`axios.create({ signal })`），这是个**真实存在的坑**，
本项目刻意不抄：

1. `AbortSignal` 是一次性闩锁（`aborted` 永不回退）；
2. axios 的 `mergeConfig` 里 `signal` 不在 `mergeMap`，走 `mergeDeepProperties`——
   `getMergedValue` 对「非纯对象、非数组」直接 `return source`，于是**实例默认值里的信号
   会随每次请求一起进管线**；
3. `dispatchRequest` 开头的 `throwIfCancellationRequested` 在适配器之前拦下
   （`config.signal && config.signal.aborted` → `throw new CanceledError(...)`）。

合起来就是：在实例默认值里放一个信号，`abort` 一次之后，**这个实例之后的所有请求全部秒失败**，
而且没人会想到是几个月前那行 `create({ signal })` 干的。

本项目的做法是把它变成**编译期就不成立**的事：`Config` 没有 `signal` 字段，信号只从三个入口
（与七个快捷方法）的 `signal?` 参数进来。老代码里的 `Config::with_signal(...)` 会直接编译不过
——这是刻意的响亮失败，迁移方式是把它挪到调用点：

```moonbit nocheck
// 以前（已删除，编译不过）
api.request(Config::new("/x").with_signal(controller.signal()))

// 现在
api.request(Config::new("/x"), signal=controller.signal())
```

代价与边界（一并接受）：

- 信号不再出现在拦截器能看到的那份配置里，也不跟着 `error.config()` 走。于是「取消之后无脑
  重试」不再自动被预检查挡住——第 3 条兜底要由写重试的人自己拿住：**要么把同一个信号一起传
  下去**，要么先判 `error.is_cancelled()`（用例 `a retry after cancel fails fast without
  another request` 与 `a retry without the signal is a brand new request` 各钉一面）。
- 想表达「这个实例发出的请求共用一个取消信号」，就自己把这个信号传给每一次调用——看得见、
  拆得掉，也不会绑架实例。

## 一个开关停掉一批请求

不需要特殊机制，显式传同一个信号即可：

```moonbit nocheck
let stop = AbortController::new()          // 应用级停机键

// 每一个希望被它停掉的请求，都把同一个信号传进去
api.request(Config::new("/downloads/a"), signal=stop.signal())
api.request(Config::new("/downloads/b"), signal=stop.signal())

stop.abort(reason="App is shutting down")  // 一次叫停全部（在飞的会立刻断）
```

「全局停机 **+** 单请求取消」两者都要时，自己管在飞请求的控制器列表（这本来也是做「取消全部」
按钮时要维护的东西）：

```moonbit nocheck
let app_stop = AbortController::new()
let in_flight : Array[AbortController] = []

// 每个请求一个控制器：请求级取消用它，停机时也能顺着列表一起 abort
let per_request = AbortController::new()
in_flight.push(per_request)
let signal = if app_stop.signal().aborted() {
  app_stop.signal()                        // 已经停机：直接给个已取消的信号
} else {
  per_request.signal()
}
```

（库**不提供** `AbortSignal::any([...])` 来做这件事，理由见「不做的事」。）

## 机制：为什么是协程级取消，而不是查标志位

`src/transport/abort.mbt` 的 `with_abort_scope` 是全部机制的唯一实现：

```
signal 有值 ——> 先查 aborted()：已取消 → 直接抛 Cancelled（一步都不跑）
                └ with_task_group ─┬─ 子任务：跑真正的 I/O（send / read）
                                   ├─ signal.attach(() => task.cancel())  ← 取消时中断它
                                   └─ task.wait() → TaskCancelled → TransportError::Cancelled
signal 为 None → 直接跑，不建任务组（零额外开销）
```

为什么不是「每次读写前看一眼信号有没有取消」：

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

## 两条兜底：取消晚一步为什么也算数

「取消发生在两段 I/O 之间」是真实存在的窗口：重定向的两跳之间、两次响应体读取之间、
「响应头到手但还没开始读」之间。这段窗口里没有可供中断的挂起点，所以必须靠**显式检查**。
本项目有两条：

1. **进入取消作用域时先查 `aborted()`**（`with_abort_scope` 开头）：已经取消就一步都不跑，
   直接抛 `Cancelled`。它挡住「跳与跳之间」——旧实现里这条是靠「登记即补触发」实现的
   （`attach` 到已取消的信号会立刻调 `task.cancel()`），现在改成看得见的检查。
2. **读取入口先查 `aborted()`**（`aborted_failure`）与 **`ResponseBody::open` 的检查**
   （拿到的流已经死了就立刻关连接，随后任何读取都报取消）。

检查与登记之间不会漏掉取消：另一条协程只在**挂起点**才可能运行，而「查一眼 → 登记」之间
没有挂起点。`src/transport/abort_wbtest.mbt` 钉着第 1 条，
`src/cancel_test.mbt` 的重定向用例钉着第 2 条在真实链路上的效果。

⚠️ 与 `CancelToken` 时代最大的行为差异：**登记本身不再补触发**（`attach` 到已取消的信号
既不触发也不保留，返回无票——与 JS 的 `addEventListener` 一致）。所以**新增任何可取消的
I/O 路径时，必须自己在入口先查 `aborted()`**，别再指望「挂上去就会被叫醒」。

## 检查与中断落在哪

| 时机 | 落点 | 行为 |
|---|---|---|
| 请求进入管线**之前** | `Client::request` / `open_stream` 里的 `check_cancelled`（合并配置之后、请求拦截器之前；信号来自入口的 `signal?`） | 立刻抛 `ERR_CANCELED`：**不发任何 I/O，也不跑请求拦截器**（拦截器可能带副作用） |
| 每一跳发送**之中** | `AsyncHttpTransport::send` 的取消作用域包住 `send_head` | 打断挂起的建连 / 写头 / 写 body / 等响应头 |
| 进入一段 I/O **之前** | `with_abort_scope` 开头的 `aborted()` 检查 | 补上窗口期：重定向的两跳之间、两次响应体读取之间 |
| 响应体读取**之中** | `read_or_fail` 的取消作用域（`read_some` / `read_until` / `read_all` / SSE 都经过它） | 打断挂起的读，抛 `TransportError::Cancelled` |
| 取消已经发生**之后** | 读入口先查 `aborted_failure`；`ResponseBody` 自己挂在信号上的「取消即 `close()`」 | 报取消而**不是**退化成 EOF；同时立刻释放连接（调用方取消后不再读也不漏连接） |

覆盖范围：三个入口都覆盖。`request` 是整条链（重定向 + 读全量），`stream` / `sse`
既覆盖建连与取响应头、也覆盖之后的每一次读取——所以「取消一条已经在消费的 SSE 长连」
是真的可用，不是只能取消握手。

## 取消长什么样

```
TransportError::Cancelled(reason)  →  ErrorCode::Cancelled  →  "ERR_CANCELED"
```

- `ErrorCode::Cancelled` 是第 8 类错误码，对应 axios 的 `AxiosError.ERR_CANCELED`；
  与超时（`ECONNABORTED`）**分开**，调用方才能把「用户主动中止」和「超时兜底」区别对待
  ——前者通常不该重试、也不该报给用户。
- `TransportError::Cancelled` **带着取消理由**（`signal.reason()`，可能为 `None`）：
  信号不在配置里，上层没有别的地方能找到它——理由只能由抛错的那一方
  （`with_abort_scope` / `aborted_failure`）随手带上。措辞仍由根包一处决定
  （`cancelled_message`：有理由用理由，没有用默认文案「请求已取消」）。
- **`AbortError` 不跨库边界**：`AbortSignal::throw_if_aborted()` 需要抛点东西，而 `abort` 包
  不能引用根包的 `HttpError`（会成环），所以它抛自己的 `AbortError`。根包在**唯一一处接壤**
  ——`client.mbt` 的 `check_cancelled`——接住它并用 `abort_error` 翻成统一的 `HttpError`。
  使用者因此只会看到一套错误体系：`is_cancelled()` 为真、错误码 `ERR_CANCELED`。
- **错误里带已经收到的响应**：取消发生在响应头到手之后时，状态行、响应头与已读到的字节
  都挂在 `HttpError::response()` 上——与超时、断连的口径一致（`docs/04-errors.md` 的
  「失败时带上已经收到的响应」那条规则）。请求还没发出去就取消时是 `None`。
  这一点与 axios 不同：axios 的 `CanceledError` 不带响应。

## 与其它能力的关系

**与 `timeout`**：两者是独立的中断手段，先到的说了算。取消作用域**在超时的错误收敛之外**，
所以取消比超时先到时报的是取消而不是 `ECONNABORTED`（用例 `cancel reports cancelled rather
than a timeout when it lands first` 钉着）。`timeout` 的语义没有因为取消改变：仍然是「建连
到响应头整体一个时限 + 响应体每次读取一个时限」。

**与拦截器**：取消是**请求阶段**的失败，走**请求侧**错误处理器（`RequestErrorHandler`）——
与本项目「错误按来源分流」的口径一致（见 `11-interceptors.md`），不做特判。想把它当正常收场
处理，在处理器的开头写 `if error.is_cancelled() { raise error }` 原样抛出即可。
重试的写法要注意：重试配方是拿 `error.config()` 再调一次 `Client::request`，而**信号不跟着
配置走**——要把取消语义带进重试，就在那次调用里把同一个信号一起传下去（这样它会撞上预检查、
立刻失败、不产生第二次请求）；不带就是一次干净的新请求。想少写这一步，就在重试前先判
`error.is_cancelled()`。

**与进度回调**：回调跑在可被取消的子任务里（上传的回调在发送子任务、下载的回调在读全量子
任务），所以在回调里调 `controller.abort(...)` **立刻对这一段生效**——下一块不会再写 / 不会再读。
这正是给 `noraise` 回调配上同步 `abort` 的意义：回调拿不到任何返回信号，但随手能喊停。
两条用例（`cancelling from the upload/download progress callback stops the …`）分别钉住上传
与下载。

**与 `MockTransport`**：Mock **不模拟取消中断**——它是同步返回的，没有挂起点可中断。这与
「Mock 不上报上传进度」（`docs/10-progress.md`）是同一种诚实声明。Mock 上仍然成立的是
**预检查**那一条（「已取消的信号让请求什么都不做」，用例在 `src/cancel_test.mbt`）；
要验证「打断挂起的 I/O」必须起真实连接，那批用例都在真机 server 上跑。

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 形态 | `AbortController` + `signal`（`cancelToken` 已弃用但仍在） | 同形态；**不支持 `cancelToken`**，只留 `signal` 一套 |
| **信号的位置** | 请求配置的 `signal`，也可以放进实例默认值（`axios.create({ signal })`） | **只能按请求传**（三个入口与七个快捷方法的 `signal?` 参数）；`Config` 里没有这个字段，放进实例默认值在编译期就不成立 |
| 判定取消 | `axios.isCancel(err)`（看 `__CANCEL__` 标记） | `HttpError::is_cancelled()`（看 `code()`） |
| 取消理由 | `signal.reason` 可以是任意值；默认是一个 `DOMException`（`AbortError`） | `reason` 收敛成 `String?`（静态语言里的简化）；默认文案是中文「请求已取消」，随取消错误一起传上来 |
| `throwIfAborted` | 抛 `signal.reason` 本身 | 抛本项目的 `AbortError`；到库边界归一成 `HttpError`（见上） |
| 组合信号 / 超时信号 | `AbortSignal.any([...])` / `AbortSignal.timeout(ms)` | 没有对应物（见「不做的事」） |
| 取消错误的上下文 | `CanceledError` 不带 `response` | 带上**已经收到的响应**（半截正文也在），与超时 / 断连一致 |
| 中断范围 | 取决于适配器（浏览器 XHR、node http） | 建连、写请求、等响应头、读响应体、SSE 事件读取都可中断 |

## 注意事项（改动时）

1. **机制只在一处**：打断动作（`with_abort_scope`）与读取前的检查（`aborted_failure`）
   都在 `src/transport/abort.mbt`。新增会挂起的 I/O 路径时，把它包进取消作用域，**并且在
   入口先查一次 `aborted()`**——对底层库的依赖仍然只允许出现在 `transport` 包里
   （`docs/README.md` 的同步清单第 4 条）。
2. **不能把取消做成「错误里的一个变体就完事」**：取消在协程模型里是**信号**，`catch` 抓不住
   它（`defer` / `errdefer` 会跑）。所以 `with_abort_scope` 必须自己 `task.wait()` 并把
   `TaskCancelled` 翻译成 `TransportError::Cancelled`；指望上层 catch 是抓不到的。
3. **登记不再补触发**（`src/abort/abort.mbt` 的 `attach`）：已取消的信号上登记既不触发也
   不保留。别指望「挂上去就会被叫醒」，登记点必须自己先查 `aborted()`——重定向第二跳、
   响应体 `open`、每次读取都是靠这条挡住的。
4. **信号只从入口进来**：要新增一个「能取消的入口」，就照样加 `signal?` 参数并往下透传
   （`dispatch_request` → `send_following_redirects` → `prepare_request` →
   `build_prepared_request` → `PreparedRequest::signal`）。**别把信号塞回 `Config`**——
   那正是 axios 那个坑的源头。
5. **一次性状态**：信号取消后不可复用，`abort` 幂等。别加「重置」——那会让「已取消」这个
   判断在并发路径上失去意义。
6. **同步段不可中断**：取消只在挂起点生效，一段纯计算（超大的 JSON 解析、回调里的长循环）
   不会被打断。要让它可中断，得在中间插 `@async.pause()`。
7. **清理沿用既有路径**：`send_head` 的 `errdefer client.close()`、`read_some` 的
   `errdefer self.close()`、`read_all_partial` 尾部的 `self.close()` 在取消时照样跑
   （README：取消信号会触发 `defer` / `errdefer`），所以没有新增清理代码。改这些清理路径时
   别忘了取消路径也在依赖它们。
8. **流式的取消不能退化成 EOF**：读入口先查 `aborted_failure` 就是为了这个。少了它，
   `while stream.read_some() is Some(_)` 会安静收场、`next_event()` 会返回 `None`，调用方
   会以为对端正常结束。
9. **开销**：设了信号之后，每一跳发送与每一次读取各多一层任务组；没设信号时不建任务组、
   零开销。这与「设了 `timeout` 时每次读取本来就包一层 `with_timeout`」同量级。

## 不做的事

- **把 `signal` 放回配置 / 实例默认值**：见上文「信号为什么不是配置字段」——这是刻意与 axios
  不同的一处，别再「补」回来。
- **`AbortSignal::any([...])`（组合信号）**：MoonBit 没有弱引用，组合信号只能把登记挂在每个
  源信号上，长命源 + 高频组合会持续累积登记。要「任一条件成立就停」，用上面的
  「一个开关停掉一批请求」写法自己管。
- **`AbortSignal::timeout(ms)`**：它需要异步运行时与任务生命周期宿主（`abort` 包不碰
  `@async`），而且与 `Config::timeout` 的语义重复——请求的时限已经由 `timeout` 表达。
- **`cancelToken` 兼容层**：只留 `signal` 一套，不维护第二套字段、管线与文档。
- **信号复用 / 重置**：一次性的（与平台一致）。
- **父子信号链**（一个信号取消一组子信号）：现在的做法是共享同一个控制器。
- **把 `timeout` 改写成信号**：二者语义不同（超时是「等太久了」，取消是「不要了」），
  合并成一层只会让错误码与文案都要多一层特判。
- **`MockTransport` 上报取消中断**：见上文「与 `MockTransport`」。
- **取消重定向的中间处理**：重定向的两跳之间没有用户回调，取消在这一层的落点就是
  `with_abort_scope` 开头那次检查。
