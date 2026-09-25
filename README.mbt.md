# moonhttp

MoonBit 上的 HTTP 客户端。网络 I/O 交给官方异步库 `moonbitlang/async`，上层这套 API 负责配置、发请求与读响应：调第三方 REST API、上传文件、消费 SSE 流，一次配置就能发请求，不必先读懂底层传输的类型。

它提供实例化配置与合并、`request` / `stream` / `sse` 三个入口、四种请求体形态、自动重定向、代理隧道、上传下载进度回调、请求与响应拦截器、取消请求、SSE 事件解析，以及一组按失败原因分类的错误码。API 语义参考 axios，代码为原创实现，未移植其源码。

## 安装

```bash
moon add q2316367743/moonhttp
```

`moon.mod` 里会记录：

```toml
import {
  "q2316367743/moonhttp@0.2.0",
}
```

默认构建目标是 `native`。

## 快速开始

```moonbit nocheck
///|
async fn main {
  // 实例上一次性配好 base_url 与公共头，之后的请求只写路径
  let api = @moonhttp.create(
    @moonhttp.Config::default()
      .with_base_url("https://api.github.com")
      .with_timeout(5_000)
      .with_common_header("Accept", "application/vnd.github+json"),
  )

  let res = api.request(
    @moonhttp.Config::new("/repos/moonbitlang/core").with_params({
      "per_page": 3,
    }),
  )

  println(res.status) // 200
  println(res.text()) // 响应体原文，按 response_encoding 解码（默认 UTF-8）
  println((try! res.json()).stringify()) // 要对象就 json()
}
```

覆盖更多场景的示例在 [`src/main/`](https://github.com/q2316367743/moonhttp/blob/master/src/main/README.md)：
快速上手那段（文本响应、JSON、查询参数、实例派生、错误处理、拦截器）用 `moon run src/main` 执行（需要联网），
另有七个方向各一个可单独运行的包——`basics`（状态码 / 头 / 查询参数 / 编码 / 错误 / 超时）、
`methods`（请求方式 × 请求体形态 × 响应内容）、`proxy`、`progress`（上传下载进度与 5% 取消）、
`redirect`、`interceptors`、`sse`，跑法都是 `moon run src/main/<方向>`。

## 功能与用法

### 实例与配置合并

配置分三层：内置默认值、实例默认值（`create` / `Client::new` 传入的）、本次请求。合并不是简单覆盖，`None` 表示「未提供」，一律回退：

| 字段 | 合并方式 |
|---|---|
| `url` / 请求方法 / 请求体 | 只取请求级，实例默认值里的同名字段丢弃 |
| `base_url` / `timeout` / `max_redirects` / `response_encoding` / 进度回调 / `cancel_token` | 请求级优先，缺省回退实例默认值 |
| `params` / `headers` / `auth` / `proxy` | 逐层合并（头名大小写不敏感） |
| `validate_status` / `params_serializer` | 请求级提供即整体接管 |

```moonbit nocheck
// 从既有实例派生：继承默认值与拦截器，再叠加本次的配置
let search = api.create(@moonhttp.Config::default().with_timeout(15_000))
```

请求方法缺省时按「实例默认值 → `GET`」回退，`api.defaults()` 可以看实例当前的默认配置；状态码默认只认 2xx，想关掉校验就传一个恒真函数（`with_validate_status(fn(_) { true })`）。

### 三个入口

| 入口 | 拿到什么 | 什么时候用 |
|---|---|---|
| `client.request(config)` | `Response`，响应体已读全 | 常规请求 |
| `client.stream(config)` | `StreamResponse`，原始字节流 | 下载、自己按块处理 |
| `client.sse(config)` | `SseStream`，解析好的事件流 | 消费 SSE |

三者的配置合并与状态码校验完全一致，区别只在响应体怎么读。

### 快捷方法

`get` / `post` / `put` / `delete` / `patch` / `head` / `options` 七个方法，都是 `request` 的薄封装：签名统一是 `(url : String, config? : Config)`，动词与方法名一致。

```moonbit nocheck
// 只要 url
let repos = api.get("/repos")

// 其余配置照旧走 config：query、超时、实例默认值（base_url、公共头）都在
let page = api.get("/repos", config=@moonhttp.Config::default().with_params({ "page": 1 }))

// 请求体也走 config：形态由 with_data_from_* 决定（json / str / form / urlencoded）
api.post("/users", config=@moonhttp.Config::default().with_data_from_json({ "name": "moon" }))
api.delete("/users/1")
```

两条优先级：**`url` 位置参数赢过 `config.url`**；**动词赢过 `config` 里的 `with_method(...)` 与实例默认方法**——`api.get(...)` 一定是 GET。除此之外与 `client.request(...)` 完全一致：实例默认值、三层头、拦截器、重定向、进度回调、取消、状态码校验一个不少。请求体不进参数列表，因为四种形态各有构建器，挑一种当参数只会让另外三种绕远路。

### 请求体：四种形态

| 构建器 | 发出去的内容 | 自动补的 `Content-Type` |
|---|---|---|
| `with_data_from_str(s)` | `s` 的 UTF-8 字节，一个字节不改 | 不补 |
| `with_data_from_json(j)` | `j.stringify()` 之后的 JSON 文本 | `application/json` |
| `with_data_from_form(form)` | `multipart/form-data` 正文 | `multipart/form-data; boundary=...` |
| `with_data_from_urlencoded(j)` | `a=1&b=2` 形式 | `application/x-www-form-urlencoded` |

```moonbit nocheck
// JSON 请求体
api.request(@moonhttp.Config::new("/users")
  .with_method(@moonhttp.Method::Post)
  .with_data_from_json({ "name": "moon" }))

// 带文件的表单：文件按「字节 + 文件名」传入，库不读盘
let form = @moonhttp.FormData::new()
  .append_text("title", "假期照片")
  .append_file("avatar", "a.png", bytes, content_type="image/png")
api.request(@moonhttp.Config::new("/upload")
  .with_method(@moonhttp.Method::Post)
  .with_data_from_form(form))
```

两点容易踩：**「是不是 JSON」由你选的方法决定，不由值的类型决定**——`with_data_from_json("hi")` 发出去的是带引号的 `"hi"`，`with_data_from_str("hi")` 发出去的是裸 `hi`；自动补的 `Content-Type` 是「补默认值」，你自己设了就一个字节都不改。

### 读响应

```moonbit nocheck
res.text()           // 按 response_encoding（默认 UTF-8）解码成文本
res.bytes()          // 原样取出字节，不经过任何解码
try! res.json()      // 先按同一编码解码，再 @json.parse（失败抛 @json.ParseError）
res.content_length() // 响应体字节数
res.is_success()     // 状态码是不是 2xx
```

状态行与响应头在 `res.status` / `res.status_text` / `res.headers` 上。库不做自动解析：`json()` 必须显式调用，它也不看 `Content-Type`——能拿到 `Response` 说明 HTTP 这一层已经成功，文本要自己解析就不调它。

### 拦截器

请求侧在发送前改配置，响应侧在拿到响应后改响应；两侧各有一个错误处理器，**按失败来源分流**——请求阶段的失败（被拦下、连不上、超时、被取消、重定向超限）走请求侧，状态码没通过校验（默认 2xx 以外的响应）走响应侧。拦截器挂在**实例**上：

```moonbit nocheck
let plain = @moonhttp.Client::new() // 给重试用的裸实例：不带这层拦截器，天然不会无限递归
let client = @moonhttp.Client::new(
  interceptors~ = @moonhttp.Interceptors::new()
    // 请求侧：发送前改配置（加认证头、改地址、给所有请求注入公共 body 字段）
    .use_request(config => config.with_header("X-Token", "secret"))
    // 请求侧的错误路径：网络类失败的重试写这（下面两处是同一个写法，写在哪一侧
    // 决定它会看到哪一类失败）
    .use_request(config => config, on_rejected=error => plain.request(error.config()))
    // 响应侧：原样返回就只是观察；要改就用 with_status / with_headers / with_body / with_text / with_json
    .use_response(response => response)
    // 响应侧的错误路径：只有「请求成功、状态码不是 2xx」会走到这——按状态码分支的重试与降级写这
    .use_response(response => response, on_rejected=error => plain.request(error.config())),
)
```

- 顺序：请求侧**后注册先跑**（LIFO）、响应侧**先注册先跑**（FIFO），两个方向相反。
- 错误处理器返回一个 `Response` 就是「这次失败救回来了」（它直接成为 `request` 的结果），返回不了就 `raise error` 继续往外抛。
- 拦截器拿到的配置是合并后的；`client.create(...)` 派生的实例会继承这份链。
- 一次请求只跑一遍：跟 5 跳重定向也只跑一次。两个错误处理器与响应链都只作用于 `Client::request`——两个流式入口只过请求拦截器。
- 闭包要写箭头形式（`config => ...`）或显式标 `async fn`——效果推断只认箭头语法，具名同步函数传不进去。
- 给一条起名（`use_request(f, name="auth")`）就**可寻址**：同名再注册**替换原位**（换 token 源不必先撤再注册），`remove_request("auth")` 按名撤下，名字没注册过返回 `None`。撤下发生在**建实例之前**——要给某个实例少挂一条，就把裁过的链交给它：`Client::new(interceptors~ = base.remove_response("unwrap").unwrap())`。语义细则见 [docs/11](docs/11-interceptors.md)。

### 取消请求

一个 `CancelToken` 可以传给任意多次请求，从任何地方喊停（另一条协程、进度回调、看门狗）：

```moonbit nocheck
let stop = @moonhttp.CancelToken::new()

@async.with_task_group(group => {
  let running = group.spawn(() => {
    api.request(@moonhttp.Config::new("/reports/big.csv").with_cancel_token(stop)) catch {
      error if error.is_cancelled() => println("已取消：" + error.message())
    }
  })
  @async.sleep(2_000)
  stop.cancel(message="Operation canceled by the user.")
  running.wait()
})
```

取消能打断挂起中的连接动作（等首字节、建连、传大 body、读响应体），流式入口在消费过程中取消也生效（下一次读取抛 `Cancelled`，而不是退化成流结束）。token 是一次性的，`cancel` 给的 message 就是错误文案；取消发生在响应头到手之后时，错误里带着已经收到的部分响应。

### 自动重定向

`max_redirects` 默认 5 跳，设成 `0` 就是不跟随（3xx 原样交给状态码校验），三个入口都跟。跨 host 跟随时会丢掉 `Authorization` / `Cookie` 这类凭据；跟到超限抛 `TooManyRedirects`，错误里带着最后那个 3xx 响应。

### 代理

```moonbit nocheck
let client = @moonhttp.create(
  @moonhttp.Config::default()
    .with_base_url("https://api.example.com")
    .with_proxy("127.0.0.1", port=9000, username="mikeymike", password="rapunz3l"),
)
```

http 与 https 目标都经 `CONNECT` 隧道转发（代理服务器得支持 `CONNECT`）。`username` / `password` 只落在建隧道的那个请求上，不会发给目标服务器。只支持 http / https 代理，不读 `http_proxy` 之类的环境变量；配了代理却没给 host 会直接报错，不会悄悄直连。

### 上传与下载进度

```moonbit nocheck
client.request(
  @moonhttp.Config::new("/upload")
  .with_method(@moonhttp.Method::Post)
  .with_data_from_json({ "name": "moon" })
  .with_on_upload_progress(fn(event) { println("已上传 \{event.loaded} 字节") })
  .with_on_download_progress(fn(event) { println("已下载 \{event.loaded} 字节") }),
)
```

`ProgressEvent` 只有 `loaded`（已传输字节）与 `total`（总字节，`None` 表示长度未知，chunked 响应与压缩响应都可能不准），外加算比例的 `progress()`；方向由哪个回调被调用表达。下载进度由「库读全量」的两条路（`request` 与 `read_all`）触发，自己按块读时自行累加。回调是同步执行且不允许抛错的，别在里面做耗时的事。

### 流式响应与 SSE

`request` 会把响应体读全，SSE 这类一直不结束的响应要用另外两个入口。

```moonbit nocheck
///|
async fn download(api : @moonhttp.Client) -> Unit raise @moonhttp.HttpError {
  let res = api.stream(@moonhttp.Config::new("/big-file"))
  println(res.status) // 响应头已到手，body 还没读
  while res.read_some() is Some(chunk) {
    println(chunk.length())
  }
}
```

```moonbit nocheck
///|
async fn watch(api : @moonhttp.Client) -> Unit raise @moonhttp.HttpError {
  let events = api.sse(@moonhttp.Config::new("/events"))
  while events.next_event() is Some(event) {
    println(event.event + ": " + event.data) // message: {...}
  }
}
```

`StreamResponse` 还有 `read_all()` 与 `read_until(分隔符)`；`SseEvent` 带 `event`（缺省 `"message"`）、`data`、`id` 与 `retry`（后两者是持久状态，断线重连要用）。读到 EOF 会自动关连接，**中途结束时记得自己 `close()`**——本项目没有连接复用，忘记关就漏一条连接。`Client::sse` 要求响应头声明 `text/event-stream`，拿到的不是事件流会报 `NotSupported`；服务端不声明却是 SSE 的场合，用 `Client::stream` 配公开的 `SseParser` 自己驱动。

### 错误处理

失败抛 `HttpError`，它带着错误分类、出错时的配置，以及**已经收到的响应**（`None` 表示连响应头都没收到）：

```moonbit nocheck
try {
  ignore(api.request(config))
} catch {
  @moonhttp.HttpError(info) => {
    println(info.code) // BadRequest
    println(info.message) // 请求失败，状态码 404
    println(info.response.unwrap().status) // 404
    println(info.config.url) // 出错时的配置，便于定位
  }
}
```

| `ErrorCode` | 触发时机 |
|---|---|
| `BadRequest` | 状态码 4xx 且未通过校验 |
| `BadResponse` | 状态码 5xx（或其它非 2xx） |
| `Network` | 连接 / DNS / TLS 失败、读响应体中途断连、代理拒绝建隧道 |
| `Timeout` | 超过 `timeout` |
| `Cancelled` | 被 `CancelToken` 取消（`error.is_cancelled()`） |
| `InvalidUrl` | 既没有 `url` 也没有可用的 `base_url` |
| `NotSupported` | 传输层无法完成该请求（例如重定向到非 http(s) 协议） |
| `TooManyRedirects` | 重定向次数超过 `max_redirects` |

### 用 Mock 传输层测试

传输层是可替换的 `Transport` trait，测试时换掉真实网络（记得在自己的 `moon.pkg` 里加上 `"q2316367743/moonhttp/transport"`）：

```moonbit nocheck
let mock = @transport.MockTransport::new(response)
let transport : &@transport.Transport = mock
ignore(@moonhttp.Client::new(transport=transport).request(@moonhttp.Config::new("/users")))
println(mock.last_request().unwrap().url) // 已经拼好 base_url 与 query 的完整地址
```

`MockTransport` 会记下收到的每个请求，也能预置一串响应或固定失败（`from_responses` / `failing`）；自定义传输只需实现一个 `send` 方法。

## 暂不支持与后续计划

以下能力本版没有实现，配置里也不会出现对应字段（避免「配置了但完全不生效」）：

- **请求体流式上传**：请求体目前是一次性字节，表单含文件时整块驻留内存；计划下一期做可写流，让调用方一段段喂数据。
- **连接复用**：每次请求新建连接，计划做连接池以省掉重复握手。
- **cookie**：不管理 cookie（没有 `withCredentials` / `xsrf*`，响应里的 `Set-Cookie` 也读不到）；计划做跨请求复用。
- **SSE 自动重连**：`id` / `retry` 已经作为持久状态带出来了，按 `retry` 间隔重订阅留给上层；计划内置。
- **响应体自动解析**：读法由你在 `text()` / `bytes()` / `json()` 里显式选；静态类型下「猜内容类型」需要先重新设计响应类型的形态。
- **`transformRequest` / `transformResponse`**：不做成独立配置项——请求体固定为四种形态，响应体读法在 `Response` 上，要「发请求前换 body」「拿到响应后改正文」就在两段拦截器里做。
- **拦截器的** `runWhen`（按条件跳过）与 `synchronous`（批量注册）：条件写在拦截器体内 `if` 即可，批量注册用链式 `use_*`。（`eject` 的等价物是具名注册 + `remove_request` / `remove_response`，见上面「拦截器」一节；`clear` 不算缺口——那等于从 `Interceptors::new()` 起步。）
- **重定向的** `beforeRedirect` 回调与自定义敏感头名单。
- **代理的** SOCKS 支持、`http_proxy` / `no_proxy` 环境变量，以及按请求关掉代理的开关（显式 `with_proxy` 已支持）。
- **单条头的多值**：一个头名只能对应一个字符串值。

## 参与开发

代码在 `src/` 下（七个功能包 + 一组可运行示例），实现思路、契约与改动清单在
[`docs/`](https://github.com/q2316367743/moonhttp/blob/master/docs/README.md)。

```bash
moon check              # 类型检查
moon test               # 全部测试（不需要外网）
moon run src/main        # 快速上手示例（真实网络，本地手动测试用，不随包发布）
moon run src/main/proxy  # 其余七个方向同理：把 <方向> 换成 basics/methods/proxy/
                         # progress/redirect/interceptors/sse 之一
moon info && moon fmt   # 更新 .mbti 接口并格式化，提交前跑一次
```

示例的索引（每个演示什么、前置条件是什么）在
[`src/main/README.md`](https://github.com/q2316367743/moonhttp/blob/master/src/main/README.md)，
维护者视角的取舍与「加一个新示例要做什么」在 [`docs/13`](https://github.com/q2316367743/moonhttp/blob/master/docs/13-runnable-examples.md)。

提交前建议把钩子装上，每次 commit 会自动跑一遍 `moon check`：

```bash
chmod +x .githooks/pre-commit && git config core.hooksPath .githooks
```

CI 会跑 `moon check --deny-warn`、`moon build`、`moon test`，并要求 `.mbti` 接口文件与 `moon fmt` 的结果没有 diff。动手改代码前先看 `docs/README.md` 末尾的「改动时的同步清单」。

## 许可证

Apache-2.0，见 [LICENSE](https://github.com/q2316367743/moonhttp/blob/master/LICENSE)。
