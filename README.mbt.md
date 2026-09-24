# moonhttp

axios 风格的 MoonBit HTTP 客户端。当前实现聚焦三件事：**创建实例**、**通用 `request`**、**配置合并**；并在此基础上提供**流式响应与 SSE**（`Client::stream` 交原始字节流，`Client::sse` 交解析好的事件流）。

设计上刻意留出扩展点（可替换的传输层、`instance.create` 派生），但暂不实现拦截器、取消、重定向等 axios 高级特性——详见文末「暂不支持」。

```moonbit nocheck
///|
async fn main {
  // 创建实例：base_url 与公共头写在实例默认配置里，后续请求不必重复设置
  let api = @moonhttp.create(
    @moonhttp.Config::default()
      .with_base_url("https://api.github.com")
      .with_timeout(5_000)
      .with_common_header("Accept", "application/vnd.github+json"),
  )

  // 发请求：配置在「内置默认值 → 实例默认值 → 本次请求」之间按 axios 的规则合并
  let res = api.request(
    @moonhttp.Config::new("/repos/moonbitlang/core")
    .with_params({ "per_page": 3 }),
  )

  println(res.status) // 200
  println(res.headers.get("content-type")) // application/json; charset=utf-8
  println(res.text()) // 响应体原文：按 response_encoding 解码（默认 UTF-8）
  println((try! res.json()).stringify()) // 要对象就 json()，它就是「解码 + 解析」
}
```

## 安装

```bash
moon add q2316368843/moonhttp
```

`moon.mod` 里会记录：

```toml
import {
  "q2316368843/moonhttp@0.1.0",
}
```

本项目默认构建目标是 `native`。网络能力来自官方异步库 `moonbitlang/async`（当前版本 `0.22.2`），它在 native 后端最成熟。

## 快速开始

完整可运行示例见 [`src/cmd/main/main.mbt`](src/cmd/main/main.mbt)，用 `moon run src/cmd/main` 执行（需要联网）。它演示了文本响应、JSON 响应、查询参数、实例派生与错误处理。

## 配置合并语义

这是本项目的重点。行为严格对齐 axios `lib/core/mergeConfig.js`，但 MoonBit 没有运行时反射，因此不采用「字段 → 合并函数」查表，而是**每个字段显式写出它用哪一档策略**——打开 [`src/config/merge.mbt`](src/config/merge.mbt) 就能一眼看到每个字段的归属。

| 字段 | axios 策略 | 本项目行为 |
|---|---|---|
| `url` / `http_method` / `data` | `valueFromConfig2` | **只取请求级**。默认值里的同名字段被丢弃，即使请求没提供也不回退 |
| `base_url` / `timeout` / `response_encoding` | `defaultToConfig2` | 请求级优先，缺省则回退默认值 |
| `params` | `mergeDeepProperties` | 按 JSON 对象逐键递归合并；数组**整体替换而非拼接** |
| `auth` | `mergeDeepProperties` | 逐字段合并：默认值给 `username`、请求给 `password`，两者都在 |
| `headers` | caseless 深合并 | 头名大小写不敏感；请求级同名头覆盖默认值，默认值独有的头保留 |
| `common_headers` / `method_headers` | 深合并 + 拍平 | 优先级 `common` < 按方法 < 请求级平铺，逐层覆盖 |
| `allow_absolute_urls` | `mergeDeepProperties` | 标量上的深合并退化为「请求级有就用请求级」 |
| `validate_status` | `mergeDirectKeys` | 请求级提供即整体接管；缺省沿用默认的 2xx 规则 |
| 任何字段的 `None` | `undefined` | 一律表示「未提供」→ 回退，而不是覆盖 |

几个刻意的细节：

- **`http_method` 而不是 `method`**：`method` 是 MoonBit 的保留字，用作字段名会告警，也会影响使用者写记录字面量。构建器仍是 `with_method`（参数类型 `Method` 已说明语境），`Config::to_string()` 的标签也沿用 `method`，便于和 axios 文档逐项对照。
- **想关掉状态码校验**：axios 靠给 `validateStatus` 传 `null`（`mergeDirectKeys` 连 `undefined` 都算「存在」）。本项目传一个恒真函数即可：`with_validate_status(fn(_) { true })`。删掉这个字段只会退回默认的 2xx 规则。
- **方法缺省时的回退顺序**：`合并结果 → 实例默认值 → GET`。合并阶段 `http_method` 走「只取请求级」策略，所以 axios 也在 `_request` 里单独从 `this.defaults.method` 回退一次，本项目复刻了这个行为。

## 请求管线

`Client::request` 内部顺序与 axios 一致：

1. `merge_config(实例默认值, 请求配置)`
2. 确定请求方法（缺省回退到实例默认值，再回退到 `GET`）
3. `base_url` + `url` 拼成完整地址，再追加序列化后的 query
4. 三层头拍平成一份（`common` < 按方法 < 请求级平铺）
5. 取请求体：`Config::serialize_body()` 给出字节与**建议**的 `Content-Type`（四种形态见下文「请求体」）；有 `auth` 则补 `Authorization`
6. 交给传输层发送（`timeout > 0` 时套超时），并把响应体读到 EOF
7. 用 `validate_status` 校验状态码，失败则抛 `HttpError`

第 3～7 步的实现分别在 [`src/url/`](src/url/)、[`src/util/`](src/util/) 与 [`src/client.mbt`](src/client.mbt) 里：拼地址/头/body 与判定是纯函数（`util`），把它们拼成 `Response`、翻译错误是根包与门面类型接壤的那一层。纯函数那部分可以脱离网络单独测试。第 6 步里「读全量」是 `request` 的选择，不需要完整响应体时改用 [`Client::stream`](#流式响应与-sse) 或 [`Client::sse`](#流式响应与-sse)；响应体到手之后怎么读，由你在 `Response` 上选 `text()` / `bytes()` / `json()`（见下文「响应体怎么读」）。

失败时抛出的 `HttpError` 会带上**已经收到的响应**：响应头到手之后才可能开始读响应体，所以读取阶段的任何失败（超时、断连）都不等于「什么都没收到」——状态行、响应头与失败前读到的部分正文都会挂在错误上，见[错误处理](#错误处理)。

### 请求体：四种形态

请求体只能经四个构建器设置，`data` 字段本身是私有的——**包外也写不了 `Config` 的记录字面量 /
记录展开**（编译器直接拒绝），构造配置请一律走 `Config::new(url)` / `Config::default()` + `with_*`：

| 构建器 | 发出去的内容 | 自动补的 `Content-Type` |
|---|---|---|
| `with_data_from_str(s)` | `s` 的 UTF-8 字节，一个字节不改 | 不补 |
| `with_data_from_json(j)` | `j.stringify()` 后的 JSON 文本 | `application/json` |
| `with_data_from_form(form)` | `multipart/form-data` 正文 | `multipart/form-data; boundary=...` |
| `with_data_from_urlencoded(j)` | `a=1&b=2` 形式（与 `params` 同一套编码） | `application/x-www-form-urlencoded` |

字符串那一路最容易踩：**「是不是 JSON」由你选的方法决定，不由值的类型决定**——
`with_data_from_json("hi")` 发出去的是带引号的 `"hi"`（合法 JSON 字面量并补头），
`with_data_from_str("hi")` 发出去的是裸 `hi`（不补头）。

```moonbit nocheck
// JSON：对象、数组、字符串都行
api.request(@moonhttp.Config::new("/users")
  .with_method(@moonhttp.Method::Post)
  .with_data_from_json({ "name": "moon" }))

// 普通表单（a=1&b=2）：与 params 用的是同一个序列化器
api.request(@moonhttp.Config::new("/login")
  .with_method(@moonhttp.Method::Post)
  .with_data_from_urlencoded({ "user": "alice", "password": "s3cret" }))

// 带文件的表单：文件按「字节 + 文件名」传入，库不读盘
let form = @moonhttp.FormData::new()
  .append_text("title", "假期照片")
  .append_file("avatar", "a.png", bytes, content_type="image/png")
api.request(@moonhttp.Config::new("/upload")
  .with_method(@moonhttp.Method::Post)
  .with_data_from_form(form))

// 内置规则不合用时（例如 protobuf，或后端要 tags=a&tags=b 这种重复平键）：自己拼 + 自己设头
api.request(@moonhttp.Config::new("/other")
  .with_method(@moonhttp.Method::Post)
  .with_data_from_str("tags=a&tags=b")
  .with_header("Content-Type", "application/x-www-form-urlencoded"))
```

`with_data_from_urlencoded` 的数组/嵌套对象走 query 那套括号约定（`tags%5B%5D=a&tags%5B%5D=b`），
`null` 键跳过、空格写成 `+`；顶层不是对象时等于一份空正文。

自动补的 `Content-Type` 是**补默认值**（`set_if_absent`）：你自己设了就一个字节都不改，
代价是头与正文可能对不上（例如你钉死了 boundary）。表单的逐字节布局、
`name` / `filename` 的 WHATWG 转义、boundary 的生成规则见 [`docs/07-request-body.md`](docs/07-request-body.md)。

### 响应体怎么读：`text()` / `bytes()` / `json()`

`request` 把响应体完整读出来，交出去的是**原始字节**；怎么读由你在 `Response` 上选一个方法：

| 方法 | 做什么 | 什么时候用 |
|---|---|---|
| `text()` | 按 `response_encoding` 解码成文本 | 文本响应正文（这是最常用的一步） |
| `bytes()` | 原样取出字节，不经过任何解码 | 二进制内容、要精确字节 |
| `json()` | 先按同一编码解码，再 `@json.parse` | 确定对面是 JSON，要对象 |

`response_encoding` 决定的是解码那一步（`json()` 复用同一套规则）：

| `response_encoding` | 解码方式 |
|---|---|
| `Utf8`（默认） | UTF-8；非法字节 → 替换字符 `U+FFFD` |
| `Latin1` | 字节值即码点（`0xE9` → `é`） |
| `Ascii` | 只认 `0x00`–`0x7F`，更高的字节 → 替换字符 |
| `Utf16le` | UTF-16 小端 |

四种都是 lossy 的：该编码下非法的字节解成替换字符，**不抛错**。精确字节始终能用 `bytes()` 拿到（`content_length()` 也基于它），二进制内容或大文件请改用 `Client::stream`。

**没有默认解码的字段**——读法摆在方法上，这是与 axios 的一处刻意差异。响应体是二进制，`Response` 里只保存这一份真相：预先解好文本就等于替你选了读法（二进制被无声地解成一堆替换字符、大响应体被白白解码一次）。解码按需发生（`text()` 调几次就解几次），要反复读同一份文本时自己存一下更划算。

**`json()` 必须显式调用，它也不看 `Content-Type`**。axios 的 `res.data` 是 `any`，由 `transformResponse` + `forcedJSONParsing` 去猜内容类型；在静态类型下，那条路的终点只能是「让每个调用点自己 match 一个变体」，而猜错时（`text/plain` 的 `123` 被解成数字）还是静默的。`json()` 的失败抛 `@json.ParseError`（带出错位置）而**不是 `HttpError`**：能拿到 `Response` 说明 HTTP 这一层已经成功，两类问题分开表达更清楚。不想要对象就别调它——`text()` 拿到原文，要自己 `@json.parse` 也可以。

这些方法只在 `request` 上生效：`stream` 交的是原始字节流，`sse` 按规范固定 UTF-8 解析事件。

三种入口，读法由**调哪个方法**决定：`request` 读全量返回 `Response`，`stream` 不读返回 `StreamResponse`，`sse` 按事件读返回 `SseStream`。调错是编译错误，不需要运行时守卫。

### URL 与 query 的边界行为

- 绝对地址判定等价于 axios 的 `/^([a-z][a-z\d+\-.]*:)?\/\//i`：`//cdn.example.com/x` 算绝对地址，而 `localhost:8080/x` **不**算（冒号后不是 `//`），会正常和 `base_url` 拼接。
- `combine_urls` 去掉 base 的尾斜杠与相对路径的首斜杠，中间补恰好一个 `/`。
- query 序列化按 axios 默认的 `paramsSerializer`：
  - 数组 → `tags%5B%5D=a&tags%5B%5D=b`（**方括号会被百分号编码**，这是 axios 的真实输出）
  - 嵌套对象 → `filter%5Bstatus%5D=1`；数组里套对象 → `items%5B0%5D%5Bid%5D=1`
  - `null` 一律跳过，既不写 `key=` 也不写 `key=null`
  - 空格写成 `+`；保留下来的字符集是 `A-Za-z0-9-_.*`，`~` 反而要转义成 `%7E`（对齐 `encodeURIComponent` + axios 的额外转义表）
  - URL 里已有 `?` 时用 `&` 续接；`#fragment` 会被丢弃（axios 也是先截断再拼 query）
- 数字参数优先使用 `Json::Number` 里保存的原始字面量（`repr`）：`@json.parse` 对超出 `Double` 精度的大整数会填上它，从而避免 `123456789012345678901234567890` 被写成 `1.2345678901234568e+29`；没有 `repr` 时退回 `Double` 的最短表示（`1.0` 写成 `1`）。

## 流式响应与 SSE

`request` 会把响应体读全再解码，SSE 这类一直不结束的响应永远等不到头。两种「不读全」的读法各有一个入口，配置合并与状态码校验都和 `request` 完全一样，区别是拿到响应头就把控制权交给调用方。

**下载 / 自己按块处理**用 `Client::stream`，拿到的是原始字节流：

```moonbit nocheck
///|
async fn download(
  api : @moonhttp.Client,
) -> Unit raise @moonhttp.HttpError {
  let res = api.stream(@moonhttp.Config::new("/big-file"))
  println(res.status)                       // 响应头已到手，body 还没读
  println(res.headers.get("content-type"))
  // 边到边读，每块自己处理（下载进度就是在这上面按块大小累加）
  while res.read_some() is Some(chunk) {
    println(chunk.length())
  }
}
```

**SSE** 用 `Client::sse`，拿到的是解析好的事件流，不需要自己切事件：

```moonbit nocheck
///|
async fn watch_events(
  api : @moonhttp.Client,
) -> Unit raise @moonhttp.HttpError {
  let events = api.sse(
    @moonhttp.Config::new("/events").with_common_header(
      "Accept", "text/event-stream",
    ),
  )
  println(events.status)                    // 响应头已到手，body 还没读
  while events.next_event() is Some(event) {
    println(event.event + ": " + event.data) // message: {...}
  }
}
```

`SseEvent` 有四个字段：`event`（缺省 `"message"`）、`data`（同一事件的多条 `data:` 行用 `\n` 连接）、`id` 与 `retry`（解析器的**持久状态快照**——一旦流里出现过就跟着后面每个事件出来，断线重连要用它们；本项目不自动重连，重连逻辑写在上层）。

`Client::sse` 会检查响应头是否声明了 `text/event-stream`，不是就报 `NotSupported`——把 JSON 或二进制按事件读只会得到一堆莫名其妙的东西，宁可响亮失败。服务端不声明类型却确实是 SSE 时，用 `Client::stream` 拿原始流 + 公开的 `SseParser` 自己驱动。

要点：

- 两个流式类型各自只有一种读法：`StreamResponse` 是 `read_some` / `read_until` / `read_all`，`SseStream` 是 `next_event`。它们都可能抛 `HttpError`；`StreamResponse::is_event_stream()` 可以自查对面是不是 SSE（想按事件读请改用 `Client::sse`）；
- 读到 EOF 会自动关闭连接；**没读完就结束时必须调用 `close()`**——本项目没有连接复用也没有析构器，忘记关闭会漏一条连接。`close()` 是「到此为止」：之后 `read_some` / `next_event` 一律只返回 `None`，包括那一次读取里已经解析好、还排队等着的事件；
- 状态码校验与 `request` 一致：非 2xx 会先把错误体读完，再抛带完整响应的 `HttpError`，长连场景下能立刻看到「为什么没连上」；
- 读取失败（超时、断连）时错误里带着**已经收到的响应**：`read_all` 中途失败会把已读到的字节一起交出来（下载断在半路时，那半截就是现场），`read_some` / `read_until` / `next_event` 失败时至少还有状态行与响应头；
- `timeout` 在流式路径下，`read_some` / `read_until` 是**每次读取的等待上限**，`read_all` 是**整段读完的时限**（不是整条请求的总时限），SSE 用默认的不限时即可；
- **不要用 `read_until("\n\n")` 切 SSE 事件**：SSE 允许 CRLF / LF / CR 三种行尾，而 CRLF 流上事件边界的字节 `0D 0A 0D 0A` 里没有连续两个 LF，这个分隔符永远匹配不到（内存体上表现为整段原样返回，真实连接上会一直等到连接关闭）。细节与全部解析规则见 [docs/06-sse.md](docs/06-sse.md)。

## 可替换的传输层

真正「把字节发出去」这一步被抽象成 `Transport` trait，整个 `moonbitlang/async` 依赖只存在于 [`src/transport/`](src/transport/) 这个包里（真实实现是 `async_http.mbt`，响应体流是 `stream.mbt`）。带来的好处：

- `config` / `headers` / `merge` / `url` 四个包不依赖网络与异步，可以用普通同步测试覆盖；
- 使用方可以注入自己的实现，测试时不必真的联网。

```moonbit nocheck
// 测试里替换掉真实网络：Mock 会记录收到的请求，并返回预置响应
let mock = @transport.MockTransport::new(response)
let transport : &@transport.Transport = mock
let client = @moonhttp.Client::new(transport=transport)

ignore(client.request(@moonhttp.Config::new("/users")))
let sent = mock.last_request().unwrap()
println(sent.url)                  // 已经拼好 base_url 与 query 的完整地址
println(sent.headers.to_string())  // 已经拍平的头
```

自定义传输只需要实现一个方法：

```moonbit nocheck
///|
pub impl Transport for MyTransport with fn send(self, request) {
  // request : PreparedRequest（方法、完整 URL、已拍平的头、body、超时）
  // 返回 RawResponse（状态码、状态短语、响应头、响应体**流**）
  // 手里已经有完整响应体时用 ResponseBody::from_bytes 包一层
  ...
}
```

## 错误处理

`request` 失败时抛出 `HttpError`，它携带分类、已合并的配置、以及**已经收到的响应**（没有收到就是 `None`）：

```moonbit nocheck
try {
  ignore(api.request(config))
} catch {
  @moonhttp.HttpError(info) => {
    println(info.code)                          // ERR_BAD_REQUEST
    println(info.message)                       // 请求失败，状态码 404
    println(info.response.unwrap().status)      // 404
    println(info.config.url)                    // 出错时的配置，便于定位
  }
}
```

`response` 有三种取值，区别只在「响应收到多少」：

- **完整响应**：状态码没通过 `validate_status` 时；
- **已经收到的部分**：失败发生在响应头到手之后（读响应体时超时、断连）——状态行与响应头一定在，响应体字节是失败前读到的部分（`bytes()` / `text()` 拿到的可能只有半截）。服务端的错误正文常常已经到了一部分，这半截正是排查时最想看的东西；
- **`None`**：连响应头都没收到就失败了（连不上、DNS 失败、缺 `url`）。

错误码只说「失败是什么」（超时 / 断连 / 状态码不合规），`response` 说「已经收到什么」，两件事不混在一起。

| `ErrorCode` | axios 对应错误码 | 触发时机 |
|---|---|---|
| `BadRequest` | `ERR_BAD_REQUEST` | 状态码 4xx 且未通过校验 |
| `BadResponse` | `ERR_BAD_RESPONSE` | 状态码 5xx（或其它非 2xx） |
| `Network` | `ERR_NETWORK` | 连接失败、DNS 解析失败、TLS 握手失败；读响应体中途连接被重置 |
| `Timeout` | `ECONNABORTED` | 超过 `timeout`（axios 默认也用 `ECONNABORTED`），含读响应体中途的等待超时 |
| `InvalidUrl` | `ERR_INVALID_URL` | 既没有 `url` 也没有可用的 `base_url` |
| `NotSupported` | `ERR_NOT_SUPPORT` | 传输层无法完成该请求；`sse` 拿到的响应不是事件流 |

## 包结构

七个包构成无环依赖，每个包只依赖它真正需要的下层：

```
moonhttp/
└── src/                     业务代码全部在 src/ 下（根目录只放模块元数据与文档）
    ├── (根包)               门面 + 编排：Client / create / request / stream / sse
    │                        / Response / StreamResponse / SseStream / HttpError
    ├── config/              配置形状、Method、内置默认值、with_* 构建器、合并契约、请求体序列化
    ├── headers/             大小写不敏感的 Headers
    ├── sse/                 SSE 事件解析（纯逻辑：吃字节、吐事件）
    ├── url/                 绝对地址判定、拼接、params 序列化
    ├── util/                纯函数层：拼请求、解码、Content-Type 与状态码判定
    ├── transport/           Transport trait + AsyncHttpTransport + MockTransport
    └── cmd/main/            可运行示例
```

约定：凡是出现在公开签名里的类型，都在**用到它**的包里**再导出一次**（`pub using`），根包也再导出一份。所以日常使用只需要 `@moonhttp` 一个 import。

拆包的依据是「签名里能不能不出现门面类型」：`config` / `headers` / `url` / `sse` / `util` 都不依赖 `Response` / `StreamResponse` / `SseStream` / `HttpError`，所以能独立成包、能用同步测试覆盖、能脱离网络跑。反过来，这几个门面类型互相引用（`HttpError` 要带 `Response`，流式类型要抛 `HttpError`，`Client` 抛 `HttpError` 又返回这三个响应类型），必须同属根包——而且**只能**在根包：`pub using` 再导出不了错误构造子，`HttpError` 一离开根包，`catch { @moonhttp.HttpError(info) }` 就写不出来了（实验证据见 `docs/01-architecture.md`）。

配置合并跟着 `config` 走（它原来是一个独立的 `merge` 包）：`Config` 有私有字段（请求体）之后，别的包连 `{ ..config, x: ... }` 这种记录展开都写不出来，而合并必须逐字段构造新配置——顺带得到一条更强的保证，往 `Config` 加字段忘了配合并策略是**编译错误**（理由见 `docs/02-config-merge.md`）。

**根包因此拆成三个源文件**（同一个包，只是为了别写成一个超长文件）：`client.mbt`（`Client` + 三个入口 + 接壤层）、`http_error.mbt`（错误类型与所有抛错点）、`facade.mbt`（对外响应类型与再导出）。AGENTS.md 的 RL-04 为根包文件放宽到 1000 行，超限的文件在文件头声明例外；子包仍守 300 行（`util/` 两个文件各不足 100 行）。

测试文件不能挪到 `tests/` 之类的子目录：MoonBit 按「文件所在目录的包」归属测试，挪出去就变成了别的包的测试（白盒测试还得编进包里才能看见 `priv`，物理上不可能在别处）。

## 暂不支持

以下 axios 能力本版本**没有**实现，配置里也不会出现对应字段（避免「配置了但完全不生效」）：

- `get` / `post` / `put` / `delete` / `head` / `options` / `patch` 等快捷方法（都是 `request` 的薄封装，见「后续扩展」）
- 拦截器（`interceptors`）、取消（`CancelToken` / `signal`）
- 自动跟随重定向（`maxRedirects`）、代理（`proxy`）
- 上传进度（`onUploadProgress`）：请求体是一次性字节，不支持流式上传（表单含文件时整块驻留内存）
- 下载进度回调（`onDownloadProgress`）：没有回调字段，但流式路径下按 `read_some` 每块大小累加即可自己统计
- SSE 自动重连：事件里带了 `id` / `retry`（重连所需的全部状态），但没有按 `retry` 间隔自动重订阅、也不自动带 `Last-Event-ID`——重连策略交给上层
- 请求/响应转换器（`transformRequest` / `transformResponse`）：请求体固定为四种形态（`with_data_from_str` / `with_data_from_json` / `with_data_from_form` / `with_data_from_urlencoded`，见「请求体」），响应体交出去的是原始字节，要文本/对象分别用 `text()` / `json()`（见「响应体怎么读」）
- `withCredentials` / `xsrfCookieName` / `xsrfHeaderName`（本项目不管理 cookie）
- 响应 cookie：底层的响应 cookie 单独存放，没有并入 `headers`，所以读不到 `Set-Cookie`
- 连接复用：每次请求新建连接
- 单条头的多值：一个头名只能对应一个字符串值（axios 允许数组）

### 与 axios 的其它差异

- `Config` 的 `method` 字段在本项目里叫 `http_method`（保留字原因，见上文）。
- `Config` 的请求体是**私有字段**（构造配置只能用构建器，见「请求体」）；`multipart/form-data` 的 `name` / `filename` 按 WHATWG 规则转义（`"` → `%22`、CR / LF → `%0D` / `%0A`），axios 依赖的 node `form-data` 不做转义。
- `application/x-www-form-urlencoded` 只提供一种约定（与 `params` 共用的那套：数组/嵌套走 `tags%5B%5D=a` 括号形式、空格写成 `+`）。axios 会按 `URLSearchParams` / 对象 / `formSerializer` 选项给出多种输出；本项目要换约定就自己拼字符串 + 自己设头。
- `Headers` 内部以小写保存头名（写入时的原始拼写会被记住并用于输出），但不支持 axios 用 `false` 表示「禁止被同名默认值覆盖」的哨兵值。
- 响应体没有默认解码的字段：`Response` 只保存原始字节，`text()`（按 `response_encoding` 解码）、`bytes()`（精确字节）、`json()`（解码后 `@json.parse`）由你显式选。axios 的 `res.data` 是 `any`，靠 `responseType` / `transformResponse` / `forcedJSONParsing` 自动解析；本项目不做那一套，`json()` 不看 `Content-Type`、失败抛 `@json.ParseError`。二进制内容用 `bytes()`（或改走 `Client::stream`）。
- 没有可变的全局默认值。axios 的全局 `axios.defaults` 在本项目里对应 `@config.defaults()`（固定的内置默认值）；要定制请用 `create(...)` 或 `client.create(...)` 派生。

### 后续扩展

`request` 已经是完整的通用入口，各快捷方法只是在它之上固定方法名与 body 的位置，例如：

```moonbit nocheck
///|
pub async fn Client::get(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  let config = match config {
    Some(config) => config
    None => Config::new(url)
  }
  // with_url 已经由 Config::new 完成；这里只需补上方法
  self.request(config.with_method(Method::Get))
}
```

## 开发

```bash
moon check              # 类型检查（pre-commit 钩子跑的就是它）
moon test               # 全部测试
moon test -p q2316368843/moonhttp/merge   # 只跑某个包
moon run src/cmd/main   # 真实网络示例
moon info && moon fmt   # 更新 .mbti 接口文件并格式化
moon coverage analyze   # 覆盖率
```

测试分层：`config` / `headers` / `merge` / `url` / `sse` 五个包是纯逻辑，用同步测试逐条钉住合并语义与 SSE 解析规则；根包与 `transport` 用 `async test` 配合 `MockTransport` 跑完整管线。`src/sse_stream_test.mbt`、`transport/stream_test.mbt` 与 `src/error_test.mbt` 会各起一个本机 server（`127.0.0.1` 随机端口）——分别验证 CRLF 的 SSE 事件能在服务端停顿期间就到达、真实连接的流式读取与单次读取超时、以及「读响应体中途失败时错误里带着已经收到的部分」（内存体读得完，只有真实连接能造出「读到一半」）。同样不需要外网，只有 `src/cmd/main` 会访问真实网络。

`util` 没有自己的 `_test.mbt`：里面的函数都被根包的黑盒测试从端到端一路覆盖（`src/encoding_test.mbt` 钉四种编码、`src/request_test.mbt` 钉拼请求与错误分档、`src/moonhttp_test.mbt` 钉方法回退），再补一份单元测试只是重复覆盖。

维护者文档（实现思路、API 契约、改动清单、MoonBit 语言坑位）见 [`docs/`](docs/README.md)。
