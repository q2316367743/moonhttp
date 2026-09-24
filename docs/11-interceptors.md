# 11 拦截器

对应 axios 的 `interceptors.request` / `interceptors.response`：**请求侧改配置 + 响应侧改响应 / 救错重试**
的两段式，挂在**实例**上（`Client::new(interceptors~)`），不是请求级配置。

拦截器是 axios 高级特性里离「中间件」最近的一个，但本项目**没有做洋葱模型**：洋葱的优势场景是
transport 装饰器式架构（一个中间件同时看得到往返两侧），而本项目的管线是分阶段的、三个入口返回三种
类型、还带一段自动重定向循环——照洋葱做会踩下面「为什么不放在传输层」里那个坑。两段式拦截器覆盖
认证注入、日志、重试、缓存这些实际用法，顺序规则与 axios 逐条一致。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/interceptors.mbt` | 三个函数类型的别名、`Interceptors`（收集与注册）、两条链的驱动（顺序与错误流转） |
| `src/client.mbt` | `Client::request` 把两段链串在派发两侧；`Client::open_stream` 只串请求侧；`Client::new` / `create` |
| `src/facade.mbt` | `Response` 的四个改写入口（`with_status` / `with_headers` / `with_body` / `with_text`） |
| `src/http_error.mbt` | `HttpError::new`：包外第一次能构造错误，供请求拦截器主动中止 |
| `src/interceptor_test.mbt` | 端到端用例：改写、两侧顺序、被拦下、重试、缓存命中、重定向只跑一次、流式入口 |

## 数据结构

```moonbit
pub type RequestInterceptor   = async (Config) -> Config raise HttpError
pub type ResponseInterceptor  = async (Response) -> Response raise HttpError
pub type ResponseErrorHandler = async (HttpError) -> Response raise HttpError

pub struct Interceptors {   // 私有字段：两条链
  // requests  : Array[RequestInterceptor]
  // responses : Array[ResponseInterceptor × ResponseErrorHandler]  // 成对存放
}

pub fn Interceptors::new() -> Interceptors
pub fn Interceptors::use_request(Self, RequestInterceptor) -> Interceptors
pub fn Interceptors::use_response(Self, ResponseInterceptor, on_rejected? : ResponseErrorHandler) -> Interceptors
```

四个必须知道的口径：

- **注册是值语义、链式的**：`use_*` 不改自己，返回追加后的新值（与 `FormData::append_text` 一致）。
  传给 `Client::new` 之后视作冻结。
- **`use_response` 的两个处理器是一对**，位置关系是语义的一部分（对应 axios 的 `use(f, r)`）：
  错误处理器接住的是**排在它前面**的一切抛出的错误（请求侧、派发、更早注册的那些处理器），
  **不包括同一对里正常处理器抛出的错误**——那种错误交给更晚注册的错误处理器（promise 链里
  `then(f, r)` 的 `r` 只接「进入这一对之前」已是失败的情况）。不写 `on_rejected` 就等于
  「不管错误、继续往外传」。调用时得写标签：`use_response(f, on_rejected=r)`——可选参数不能
  按位置传（实测）。
- **闭包必须是箭头形式或显式标注 async**：MoonBit 的效果推断只认箭头语法，写 `config => ...`
  或 `async fn(config) -> Config raise HttpError { ... }`。**具名同步函数不能直接传**——
  `(Config) -> Config` 与 `async (Config) -> Config raise HttpError` 是两个类型（实测报
  `Expr Type Mismatch`），要包一层 `config => f(config)`。
- **拦截器里不能写 `assert_eq`**：链的签名只允许抛 `HttpError`，而 `assert_eq` 抛的是别的错误类型。
  断言写在拦截器外面，把要观察的东西记到闭包外的变量里再断言（实测）。

## 执行顺序

`Client::request` 的九个步骤里，两段链分别在第 3 步与第 9 步（其余七步见 `03-request-pipeline.md`）：

```
请求级 config
   │
   ├─ 1. merge_config(实例默认值, 请求级)   2. resolve_method
   │
   ▼
3. 请求拦截器 ··· 后注册先跑（LIFO，同 axios）
   │                 抛错 → 这次请求不发出，错误流入响应侧错误处理器
   ▼
4~7. 派发（dispatch_request）：拼地址 / 头 / body → 发送（含自动跟随重定向）→ 读全量 → 拼 Response
   │                 非 2xx 与传输失败在这里变成 HttpError
   ▼
8. 校验状态码（validate_status，默认 2xx）
   │
   ▼
9. 响应拦截器 ··· 先注册先跑（FIFO，同 axios）
   │                 正常处理器拿 Response；错误处理器拿 HttpError（重试的落点）
   ▼
返回 Response / 抛出 HttpError
```

与 axios 的 promise 链同构：**错误一旦出现，后续的正常处理器全部跳过，只有错误处理器有机会接住它**
（接住 = 返回一个响应或一份配置，接不住 = 继续往外传）。因此：

- 请求拦截器抛出的错误**不会**直接落到调用方，而是先进响应侧错误处理器——这是 axios 的行为
  （`dispatchRequest` 之前的 rejection 照样走响应链的 rejected），也支撑了下面的「缓存命中」写法。
- 要求拦截器拿到的配置是**合并后**的（第 1 步之后），与 axios 一致：改 URL、加头、换 body、换方法
  都直接生效。注意此时 `url` 与 `base_url` 还没拼在一起（拼接在派发里），改地址要连 `base_url` 一起想。
- 非 2xx 会经过错误处理器，所以「拿到 404 仍能读响应、仍能重试」做得到（`HttpError::response()`
  上有完整响应）。

### 三个入口的覆盖范围

| 入口 | 请求拦截器 | 响应拦截器 | 为什么 |
|---|---|---|---|
| `Client::request` | ✅ | ✅ | 完整响应在手，改写与重试都有明确语义 |
| `Client::stream` | ✅ | ❌ | 「响应」是还没读的字节流，改写它没有意义（读法由入口决定） |
| `Client::sse` | ✅ | ❌ | 同上；事件流的重试语义也不明确 |

被请求拦截器拦下时，两个流式入口**直接抛**（它们没有响应侧链可交），`request` 则先进错误处理器。

### 一次 `request` 只跑一遍拦截器

拦截器落在 `Client::send_following_redirects` 的**外面**，所以跟 5 跳重定向也只各跑一次。
这条由 `src/interceptor_test.mbt` 的 "interceptors run once for the whole redirect chain" 钉着
（断言两跳 `request_count() == 2` 而两段链各只跑 1 次）。

## 重试怎么写

错误处理器是 `async` 的，所以它能**再发一次请求**——这是「拦截器能不能做重试」的全部前提。

重试用**另一个不带这层拦截器的实例**重发，天然不会无限递归（axios 需要靠 `config._retry` 标记挡）：

```moonbit
let plain = @moonhttp.Client::new()                       // 裸实例：不带重试拦截器
let client = @moonhttp.Client::new(
  interceptors~ = @moonhttp.Interceptors::new().use_response(
    response => response,
    on_rejected = error => plain.request(error.config()),   // 重发同一份配置
  ),
)
```

有界重试（只重试一次，第二次失败原样抛出）——闭包可以捕获并修改外层的 `mut` 局部变量：

```moonbit
let mut tried = false
.on_rejected = error => {
  if tried { raise error }        // 不处理 = axios 的 Promise.reject(error)
  tried = true
  plain.request(error.config())
}
```

两个用法都在 `src/interceptor_test.mbt` 里有对应用例。`error.config()` 是**已经过请求拦截器**的合并配置，
与 axios 的 `error.config` 一致。

### 附带一个实用写法：缓存命中不发请求

请求侧没法「返回一个响应」，但可以抛错拦下，让响应侧错误处理器把闭包里存着的那份响应还回去：

```moonbit
.use_request(config => match cached {
  Some(_) => raise @moonhttp.HttpError::new("cache-hit", @moonhttp.ErrorCode::BadRequest, config)
  None => config
})
.use_response(response => response, on_rejected = error => match (error.message(), cached) {
  ("cache-hit", Some(response)) => response     // 命中：这次请求根本没发出去
  _ => raise error
})
```

代价是错误里没有响应可参考（`response()` 是 `None`），只能靠错误本身认路。用例见
`src/interceptor_test.mbt` 的 "an aborted request flows into the response error handler"。

## 写响应：四个改写入口

响应拦截器要能改响应，`Response` 才不是个只读的日志钩子。`raw` 是私有字段，包外造不出也改不了
`Response`，所以提供四个**返回新响应**的方法：

| 方法 | 改什么 |
|---|---|
| `with_status(Int)` | 状态码（`status_text` 不变） |
| `with_headers(Headers)` | 响应头，整体替换而不是合并 |
| `with_body(Bytes)` | 响应体字节（`bytes()` / `text()` / `json()` / `content_length()` 跟着变） |
| `with_text(String)` | 同上，但收文本、按 UTF-8 编码（与请求侧 `with_data_from_str` 同口径，写入方向固定 UTF-8） |

两条边界：

- **换 body 不会同步响应头**。`Content-Length` 是服务端写下的原文，本项目从不改写响应头，
  所以两者可能对不上。要一致就自己用 `with_headers` 一起换。
- **不能凭空造一个响应**。四个方法都要求手上先有一份 `Response`——非 2xx 的错误里有一份
  （`error.response()`），网络失败与被拦下的请求里没有。要从零合成一个响应（例如「网络失败降级成
  200」），本版本做不到；能做的三条路是改造错误里那份、重发一次请求、或返回之前存下来的响应
  （缓存场景正好够用，见上）。

**改状态码不会重跑校验**：`validate_status` 早在拦截器之前就跑完了。要在拦截器里把成功改成失败，
请在正常处理器里抛 `HttpError`。

## 为什么挂在 `Client` 而不是 `Config`

两条理由，第一条是硬约束：

1. **依赖方向**。`Response` 与 `HttpError` 定义在根包，而包依赖是「根包 → `config` 包」；响应拦截器
   的签名必须提到这两个类型，字段一旦进 `Config` 就成环（同一条约束把 `util` 包也挡在外面，
   见 `01-architecture.md`）。
2. **axios 的 `interceptors` 本来就是实例级的**（`axios.interceptors` / `instance.interceptors`），
   不是请求级——挂在实例上才是对齐。本项目的「请求级拦截器」在 axios 里也不存在。

连带的一条差异：**`Client::create` 派生的实例继承拦截器**。axios 的 `axios.create()` 造出来的是
没有拦截器的新实例，而本项目的 `create` 是「同一个实例换套默认值」，换默认值不该把认证头、日志
这些横切逻辑丢掉。确实要不带拦截器的实例，用 `Client::new(config~)` 新造一个。

## 为什么不放在传输层

gaato/http 那类实现把中间件做成 `Transport` 的装饰器，在本项目会踩两件事：

1. **每跳重跑一遍**。传输层的调用点在 `Client::send_following_redirects` 的循环里，一次
   `request` 里每跟随一跳就调一次 `transport.send`。中间件挂在那里，跟 3 跳就等于跑 3 遍：
   认证头重复注入、日志重复、审计重复，最糟的是**重试被放大成「跳数 × 重试次数」**。
   axios 的重定向发生在适配器内部、拦截器在其上层，整条链只跑一次——本项目的落点与它一致。
2. **三个入口三种返回类型**。洋葱的 `next` 必须有确定的返回类型，而本项目 `request` / `stream` /
   `sse` 分别返回 `Response` / `StreamResponse` / `SseStream`。想用一条洋葱链包住三个入口，
   就得先放弃这三种类型，代价远大于收益。

（对方做装饰器是干净的，因为它没有请求级重定向语义——差异根源在这里，不是谁的设计更好。）

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 注册形状 | `axios.interceptors.request.use(f, r)` 返回 id，可 `eject` | `Interceptors::use_request` / `use_response` 链式构建，无 `eject` |
| 请求侧错误处理器 | 有（成对给） | **没有**：请求拦截器能抛错中止，但「拦截器之间互相救错」不做 |
| 响应拦截器覆盖面 | 所有响应（含 `responseType: 'stream'`） | 只 `Client::request`；两个流式入口不过响应链 |
| 合成响应 | 返回普通对象即可 | 不能凭空造：只能改写已有的响应 / 重发请求 / 返回存下来的响应 |
| 请求拦截器返回值 | 返回值当成 config 继续传（不能靠它短路） | 同 axios；短路要走「抛错 → 错误处理器」那条路 |
| 顺序 | 请求 LIFO、响应 FIFO | 一致 |
| 拦截器与重定向 | 重定向在适配器内部，拦截器只跑一次 | 一致（落点在重定向循环之外） |
| `create` 与拦截器 | 新实例没有拦截器 | 派生实例继承拦截器 |
| 拦截器里的钩子 | 有 `runWhen`（按条件跳过）、`synchronous`（批量注册） | 都不做：条件写在拦截器体内 `if` 即可 |

## 不做的事

- **洋葱模型 / 中间件链**：理由见上。真要「单个函数同时观察往返两侧」或「多次调用下游」，
  本版本没有对应能力。
- **`eject` / `clear` / 按条件跳过（`runWhen`）**：注册发生在建实例之前，撤下一个拦截器直接
  重新构建 `Interceptors` 值即可。
- **请求拦截器之间的错误恢复**（axios 的 `request.use(f, r)` 里那个 `r`）。
- **流式入口的响应拦截 / 重试**。
- **从零合成响应**（见上，`Response` 只能改写不能凭空造）。
- **拦截器内的取消**：`CancelToken` / `signal` 仍未实现，中止手段是抛 `HttpError`。

## 注意事项（改动时）

1. **两条链的顺序是相反的**，改 `src/interceptors.mbt` 里 `run_request` / `run_response` 的遍历
   方向会静默改变语义。`src/interceptor_test.mbt` 的 "…run last-registered-first" /
   "…run first-registered-first" 两条用例钉着它们。
2. **别把链挪进 `send_following_redirects` 或传输层**：那会让它每跳重跑一次，理由见上；
   "interceptors run once for the whole redirect chain" 是这条的回归测试。
3. **`Result[Config, HttpError]` 是两段链之间的载体**：`run_request` 声明成 `noraise`（错误全部收进
   `Err`），这样「被拦下的错误流进响应侧」这条语义才成立。给 `Client::request` 加步骤时，
   新步骤要落在 `dispatch_request` 的 `try` 里，否则它的错误绕不过响应侧错误处理器。
4. **`Response` 的四个改写入口都只改字段、不动响应头**，加新的改写方法时保持这个口径
   （响应头是服务端写的原文，`Content-Length` 的一致性交给调用方）。
5. **`Interceptors` 的字段是私有的、注册是值语义**：别改成就地 push（会让共享了同一个值的两个实例
   互相影响），也别把它挪进 `config` 包（会成环）。
