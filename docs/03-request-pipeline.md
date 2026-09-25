# 03 请求管线

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/client.mbt` | `Client::request` / `Client::stream` / `Client::sse` 的编排：合并 → 定方法 → 取消预检查 → 请求拦截器 → 发送 →（读全量 / 交还流）→ 校验 → 响应拦截器；失败按来源分流到请求侧 / 响应侧两条错误链 |
| `src/interceptors.mbt` | 拦截器与两条错误链：`Interceptors`（注册、同名替换、按名移除，全部发生时都还没进管线，见 `11-interceptors.md`）、`run_request` / `run_request_errors` / `run_response`（顺序与错误流转） |
| `src/shortcuts.mbt` | 七个动词的快捷方法（`get` / `post` / …）：补 `url` 与动词后转调 `Client::request`，没有自己的管线（详见 `14-shortcut-methods.md`） |
| `src/config/merge.mbt` | 合并契约：四种策略、`merge_config`、`flatten_headers`（为什么在 `config` 包见 `02-config-merge.md`） |
| `src/config/body.mbt` | 请求体的四种形态与序列化：`serialize_body`（字节 + 建议的 `Content-Type`） |
| `src/config/form.mbt` | 表单的 `multipart/form-data` 编码（详见 `07-request-body.md`） |
| `src/config/progress.mbt` | 进度回调的 `ProgressEvent` / `ProgressCallback` 与两个 `with_on_*` 构建器（详见 `10-progress.md`） |
| `src/util/request.mbt` | 请求侧的纯函数：`resolve_method`、`build_prepared_request`（地址、头、body 的拼装）与只给它用的 `basic_auth` |
| `src/util/response.mbt` | 响应侧的纯函数：`decode_body`（读）、`encode_body`（写，响应拦截器改写响应体用）、`declares_event_stream`（与只给它用的 `media_type`）、`status_allowed` |
| `src/client.mbt` | 与门面类型接壤的那两个函数：`prepare_request`（把纯函数的 `None` 翻译成 `InvalidUrl` 错误）、`build_response` |
| `src/http_error.mbt` | 错误类型 `ErrorCode` / `ErrorInfo` / `HttpError` 与所有抛错点：`transport_error`、状态码分档 `status_error_code` / `status_error` / `validate_response` |
| `src/url/combine.mbt` | 绝对地址判定、`combine_urls`、`build_full_path` |
| `src/url/build_url.mbt` | `params` → query string（自定义 `paramsSerializer` 的接入点） |
| `src/url/encode.mbt` | 单个 URL 组件的百分号编码 |
| `src/facade.mbt` | 门面层：`Response`（读全量）/ `StreamResponse`（原始流）/ `SseStream`（事件流）/ `HttpError` 与各子包类型的再导出 |

`util/` 与 `url/` 里的管线函数都是**纯函数**（没有 IO、不涉及异步），可以脱离网络单独测试，`url/url_test.mbt` 就是逐条钉住边界行为的。两者的差别只在依赖：`url/` 连 `Config` 都不认识，`util/` 认识配置与传输层的数据形状（`PreparedRequest`），但不认识任何门面类型。

**七个快捷方法没有第二条管线**：`Client::get` / `post` / `put` / `delete` / `head` / `options` / `patch` 只做上面八步里第 1 步之前的两件小事——把 `url` 与动词补进配置，然后转调 `Client::request`。所以八步、两段拦截器与两条错误链、重定向、进度、取消、状态码校验在这里的落点对它们同样成立，本文后面不必再区分「快捷方法」与 `request`。契约（`url` 位置参数赢过 `config.url`、动词赢过配置与实例默认方法）见 `14-shortcut-methods.md`。

## 八个步骤

`Client::request(config)` 的顺序与 axios 的 `_request` 对齐：

1. **合并配置**：`merge_config(实例默认值, 请求配置)`（契约见 `02-config-merge.md`）。
2. **确定方法**：合并结果 → 实例默认值 → `Method::Get`。
3. **拼完整地址**：`build_full_path(base_url, url, allow_absolute_urls)`，再 `build_url(url, params)` 追加 query（配置里有 `params_serializer` 时用自定义序列化器替换「params → query 文本」那一步，见下）。
4. **拍平头**：`flatten_headers(common_headers, method_headers, headers, method)`，优先级 `common` < 按方法 < 请求级平铺。
5. **取请求体**：`Config::serialize_body()` 给出字节与**建议**的 `Content-Type`（序列化在 `config` 包内完成，见 `07-request-body.md`），有 `auth` 则补 `Authorization`。补默认头一律用 `Headers::set_if_absent`，用户显式设置的同名头永远优先。有 `proxy` 时，`Proxy-Authorization` 在这一步从目标头里取走、改落在 CONNECT 请求上（代理凭据不该发给源站，见 `09-proxy.md`）。
6. **发送**：交给 `Transport::send`（契约见 `05-transport.md`）。配了代理时先与代理建立 CONNECT 隧道，再在隧道里发出请求（见 `09-proxy.md`）。失败映射见 `04-errors.md`。收到 3xx 且带 `Location` 时**自动跟随重定向**（最多 `max_redirects` 跳，默认 5），一直跟到最后一跳——这段循环在 `Client::send_following_redirects`，规则见 `08-redirects.md`。
7. **读出响应体**：把响应体读到 EOF，字节原样放进 `Response`（解码不在这里，见下）。
8. **校验状态码**：`validate_status` 不通过时给出带响应的 `HttpError`。这一步与前面几步的失败**分流**：第 1~7 步的失败（被拦下、连不上、超时、取消、重定向超限、读体失败）走请求侧错误处理器，第 8 步的失败走响应侧错误处理器（见下）。

### 两段拦截器与两条错误链

上面八步是管线**主体**，拦截器不改这八步的分工，只夹在它两端（细节见 `11-interceptors.md`）：

- **请求侧**：夹在第 2 步与第 3 步之间。它在拼地址之前，所以拿到的配置里 `url` 与 `base_url` 还没拼在一起；
  它抛错就表示这次请求不发出，错误交给**请求侧错误处理器**（同一段链上成对注册的第二个处理器，
  它可以返回一个响应把这次失败救回来）。
- **响应侧**：夹在第 8 步之后。正常处理器拿到通过校验的 `Response`，错误处理器只接第 8 步的失败
  （状态码没通过校验，默认非 2xx）——这时错误里带着完整响应，状态码、响应头与错误正文都在。

**错误按来源分流**是本项目与 axios 的 promise 链有意不同的一处：axios 里派发失败（连不上、超时）
会落到响应侧的 rejected（它在链上接得到 `dispatchRequest` 的错误），这里只落请求侧。
理由很直接：请求阶段的失败该由请求侧救（重试、返回缓存里存的响应），响应阶段的失败才需要那份响应来判读。
分工、顺序与两条配方见 `11-interceptors.md`。

三条链都在 `Client::send_following_redirects` **之外**，所以整条重定向链只跑一遍拦截器。
三个入口都过请求侧链；**请求侧错误处理器与响应侧链只作用于 `Client::request`**
（两个错误处理器的落点都是一份 `Response`，而 `stream` / `sse` 交出去的是还没读的字节流）。

### 取消预检查：第 2 步之后、请求侧拦截器之前

配置合并完（第 1、2 步）就查一次 `cancel_token`：已经取消时立刻抛 `ERR_CANCELED`，
**既不拼地址也不跑请求拦截器**——被取消的请求什么都不做（拦截器可能带副作用）。
这一层与传输实现无关，所以 `MockTransport` 上也成立；请求发出**之后**的取消由传输层的取消作用域
负责（`05-transport.md` 的「取消语义」、完整机制见 `12-cancellation.md`）。

第 1–5 步是「拼出一份能发出去的请求」，与读不读响应体无关。第 6 步包含自动跟随重定向（`request` 与两个流式入口共用同一段循环，所以上行地址、方法与头在跟随后的形态完全一致）；第 6 步起有三种**读法**，各有自己的入口与返回类型：

| 入口 | 第 6 步之后 | 返回 | 适用 |
|---|---|---|---|
| `Client::request` | 先把响应体读到 EOF（`ResponseBody::read_all_partial`），再校验状态码 | `Response` | 常规请求，需要完整响应体 |
| `Client::stream` | 直接把响应头与响应体流交出去 | `StreamResponse` | 大文件下载、自己按块处理 |
| `Client::sse` | 交出去，但要求响应头声明了 `text/event-stream` | `SseStream` | 按事件读 SSE |

**读法由入口决定，不由配置决定。** `response_encoding` 只描述「字节怎么解成文本」，不描述读不读——「读完还是流」是调哪个方法决定的，配置字段里没法表达，也不该表达。语言层面同样没法让一个方法的返回类型随运行时配置变化：真要那样只能返回一个变体包装，调用方每次都得 match。三种读法静态分开之后，「调错了」是编译错误，不需要运行时守卫。

`Response` 拿到手之后，**怎么读**同样由方法决定，这是第二层「读法」：`text()`（按 `response_encoding` 解码）、`bytes()`（精确字节）、`json()`（先解码再 `@json.parse`）。三层入口 × 三种读法都是静态的，不存在「配置变了返回类型就变」的情况。

三种入口的**前半段与状态码校验完全一致**（`stream` 与 `sse` 共用 `Client::open_stream`，规则见 `status_allowed` / `status_error_code`）——**请求拦截器也在这段共用路径里**，所以三个入口都会被请求侧链处理过；**请求侧错误处理器与响应侧链都只在 `Client::request` 上**（两者的落点都是一份 `Response`，流式入口手里是还没读的字节流，救回没有落点）。差别只在失败时拿什么：`request` 报错时带的是完整响应，两个流式入口报错前会把错误体读完（不猜它是 JSON 还是别的什么格式——错误体格式不可预期，强行解释只会把「状态码失败」这个更准确的原因盖掉），字节放在 `HttpError::response()` 的 `Response` 上，按需要读成文本（`text()`）或原样取走（`bytes()`）。流式路径的超时语义见 `05-transport.md`，SSE 另见 `06-sse.md`。

**失败不等于什么都没收到**：响应头到手之后才可能开始读响应体，所以读取阶段的任何失败（单次读取超时、连接被重置）都已经晚于响应头——三个入口都会把**已经收到的响应**挂到错误上（状态行、响应头，以及失败前读到的部分正文，`Client::request` 与 `StreamResponse::read_all` 都用了 `read_all_partial` 保住那半截）。响应头到手之前就失败（连不上、DNS、缺 url）时错误里没有响应。判定与字段含义见 `04-errors.md`。

## 进度回调的落点

两个方向各只有一处触发点，都挂在上面那张步骤表的中间：

| 方向 | 触发点 | 时机 |
|---|---|---|
| 上传（`on_upload_progress`） | 第 6 步的 `Transport::send` 里 | 请求体按 64 KiB 分块写入连接，每块 `flush` 后回调一次（每跳重定向各报一轮） |
| 下载（`on_download_progress`） | 第 7 步读全量时（`ResponseBody::read_all*`） | 每读到一块回调一次；`Client::request` 与 `StreamResponse::read_all` 会接上回调，按块读的入口不接 |

两个回调都是 `noraise` 且同步执行，占用请求自己的时间预算；`loaded` / `total` 的确切口径、`total` 为什么会不准、Mock 为什么不触发上传进度，见 `10-progress.md`。

## URL 拼接规则

### 绝对地址判定

等价于 axios 的 `/^([a-z][a-z\d+\-.]*:)?\/\//i`：

- `https://a.com/x`、`http://a.com` → 绝对；
- `//cdn.example.com/x`、`//cdn.example.com:8080/x` → **算绝对地址**（scheme 部分可选，这是 axios 正则的真实行为；端口那个冒号属于 authority，不改变判定）；
- `localhost:8080/x` → **不算**（冒号后不是 `//`），会正常和 `base_url` 拼接；
- `/users`、`users`、`./users` → 不算。

### 拼接

`combine_urls` 去掉 base 的尾斜杠、相对路径的首斜杠，中间补恰好一个 `/`。与 axios 的唯一差异：axios 的 `/\/?\/$/` 一次只吃掉最多两个尾斜杠，本项目把所有尾斜杠都去掉，避免 `https://a///` 拼出 `https://a//x`。

### 绝对地址直连开关

`allow_absolute_urls` 缺省视为 `true`：`url` 是绝对地址时直接用，不拼 `base_url`。设为 `false` 时即使绝对地址也会拼到 `base_url` 后面（对应 axios 的 `allowAbsoluteUrls: false`）。

`base_url` 为空串时按「不存在」处理，与 axios 里 `if (baseURL && ...)` 把空串当 falsy 一致。

## query 序列化

规则对齐 axios 默认的 `paramsSerializer`（`metaTokens: true`、`dots: false`、`indexes: false`）：

| 输入 | 输出 |
|---|---|
| `{"foo": "bar"}` | `foo=bar` |
| `{"tags": ["a", "b"]}` | `tags%5B%5D=a&tags%5B%5D=b` |
| `{"filter": {"status": 1}}` | `filter%5Bstatus%5D=1` |
| `{"items": [{"id": 1}]}` | `items%5B0%5D%5Bid%5D=1` |
| `{"a": null}` | （空，整个键被跳过） |
| `{"tags": [null, "x"]}` | `tags%5B%5D=x` |

三个容易搞错的点：

1. **方括号会被百分号编码**。axios 生成的是 `tags%5B%5D=a`，不是字面的 `tags[]=a`——这是 axios 自己的测试用例里断言的真实输出。
2. **键和值都会被编码**，且用的是同一个编码函数。
3. **数字优先使用 `Json::Number` 的 `repr` 字段**（原始字面量）。`@json.parse` 只在 `Double` 无法精确表示时才填它——例如超出精度的超大整数，此时沿用它避免丢精度与变成科学计数法。没有 `repr` 时用 `Double` 的最短表示，`1.0` 写成 `1`（与 JS 的 `String(number)` 一致）。调用方也可用 `Json::number(n, repr="...")` 显式指定。

### 编码字符集

`encode_component` 等价于「`encodeURIComponent` 之后再额外转义 `! ' ( ) ~`」，因此保留下来的字符集是 `A-Za-z0-9-_.*`：

- 空格 → `+`（不是 `%20`）；
- `~` → `%7E`（标准 RFC 3986 编码器会保留 `~`，所以不能直接复用 `@encoding/percent`）；
- `[` `]` → `%5B` `%5D`；`&` `=` `/` `:` 等一律转义；
- 非 ASCII 按 **UTF-8 字节**逐个转义（按 UTF-16 码元处理会把代理对拆错），十六进制大写。

### 追加位置

URL 里已有 `?` 时用 `&` 续接，否则用 `?`；`#fragment` 会被**丢弃**（axios 先截断再拼 query，本项目保持一致）。没有参数时 URL 原样返回，不留下空的 `?`。

### 自定义序列化器（`paramsSerializer`）

内置约定不合用时（后端要 `tags=a&tags=b` 这种重复平键、逗号连接、或者别的编码表），
可以用 `with_params_serializer` 换掉序列化那一步：

```moonbit
Config::new("/search")
  .with_params({ "tags": ["a", "b"] })
  .with_params_serializer(fn(_params) {
    // 拿到的就是 params 本身，返回值就是 query 文本（不含前导 `?`）
    "tags=a&tags=b"
  })
// → /search?tags=a&tags=b（内置规则会写成 tags%5B%5D=a&tags%5B%5D=b）
```

契约与 axios 的对应关系：

- 替换的**只有**「`params` → query 文本」这一步，对应 axios `buildURL` 里的
  `options.serialize` / 老的函数形式 `paramsSerializer(params)`；
- 拼接仍由 `build_url` 负责：已有 `?` 用 `&`、丢弃 `#fragment`、
  **返回空串**时不留下空 `?`（用例在 `src/url/url_test.mbt`）；
- `params` 为 `None` 时序列化器根本不会被调用；
- 合并走策略 2（请求级提供即整体替换实例默认值，见 `02-config-merge.md`）；
- **只管 query**：`with_data_from_urlencoded` 的请求体仍走内置序列化器
  （axios 里请求体走的是另一个内部选项 `formSerializer`，见 `07-request-body.md`）；
- 落点在 `build_prepared_request`，所以三个入口（`request` / `stream` / `sse`）都生效；
  重定向时只有**第一跳**会调用它（后续跳的 `params` 已清空，见 `08-redirects.md`）。

与 axios 的差异：只接受函数形式，没有 `{ serialize, encode, indexes }` 那套对象形式，
也没有单独定制某个组件（键、值、方括号）编码器的口子。

判断「要不要用」的一条经验：约定只差「key 怎么拼」时用它；连百分号编码表都要换、
或者要发的是二进制/多部分正文时，那已经超出 query 的范围，另想办法（改 `url` 手里的
完整地址，或自己拼 `with_data_from_str`）。

## body 序列化与自动补头

`Config` 的请求体是**私有字段**，只能经四个构建器设置，字节与建议类型由 `Config::serialize_body()` 产出：

| 构建器 | 发送内容 | 自动补的头 |
|---|---|---|
| （未设置） | 不带 body | — |
| `with_data_from_str(s)` | `s` 的 UTF-8 字节，原样 | 不推断类型 |
| `with_data_from_json(j)` | `j.stringify()` 后的 UTF-8 字节 | `Content-Type: application/json` |
| `with_data_from_form(form)` | `multipart/form-data` 正文（含 boundary） | `Content-Type: multipart/form-data; boundary=...` |
| `with_data_from_urlencoded(j)` | `serialize_params(j)`（与上面的 query 同一套规则） | `Content-Type: application/x-www-form-urlencoded` |

序列化为什么在 `config` 包而不是这里：`data` 私有，只有 `config` 包能 match 四种形态；
而「body 怎么变成字节」本就是请求体类型自己的事。本层只做最后一步——把给出的建议类型
用 `set_if_absent` 落到头上。四种形态的细节（含 `Json::String` 的分水岭、multipart 布局、
urlencoded 的括号约定）见 `07-request-body.md`。

`auth` 有值时补 `Authorization: Basic base64(username:password)`，缺一半的用户名/密码按空串处理。

**补头一律用 `set_if_absent`**：用户显式设置的同名头永远优先。这条由 `src/request_test.mbt` 的四个用例守着（"json body sets content type only when absent"、"auth produces basic authorization header" 的第二个断言、"urlencoded body sets its content type"、"user content type wins over the form default"）。

## 响应体读取：`text()` / `bytes()` / `json()`

`Response` 里**只有原始字节**（`raw` 是私有字段），怎么读摆在方法上，且由调用方显式选：

| 方法 | 做什么 | 适用 |
|---|---|---|
| `bytes()` | 原样取出字节，不经过任何解码 | 二进制内容、要精确字节、想按自己的编码解 |
| `text()` | 按 `config.response_encoding` 解码成文本 | 文本响应正文 |
| `json()` | 先按同一编码解成文本，再 `@json.parse` | 确定对面是 JSON，要对象 |

`response_encoding` 决定的是 `text()` 那一步（`json()` 复用同一套解码）：

| `response_encoding` | 解码方式 | 实现 |
|---|---|---|
| `Utf8`（默认，内置默认值显式设置） | UTF-8；非法字节 → `U+FFFD` | `@utf8.decode_lossy` |
| `Latin1` | 字节值即码点（`0xE9` → `é`），任何字节序列都能解出文本 | `src/util/response.mbt` 里的 `decode_body`（core 没有，一个循环） |
| `Ascii` | 只认 `0x00`–`0x7F`，更高的字节 → `U+FFFD` | `@ascii.decode_lossy` |
| `Utf16le` | 两个字节一个码元，小端 | `@utf16.decode_lossy(endianness=Little)` |

四种都是 lossy 的：该编码下非法的字节解成替换字符，**不抛错**——响应正文由服务端说了算，为了几个坏字节把整个响应判成失败得不偿失。精确字节始终能从 `bytes()` 拿到（`content_length()` 也基于它）。

**解码是按需做的**：`Response` 不缓存文本（不存 `String`），`text()` 调几次就解几次。这样 `Response` 里只有一份真相（字节），也不会出现「字节与解码结果两份状态」。要反复读同一份文本时，调用方自己解一次存起来更划算。

**为什么没有默认解码的 `data` 字段**：`Response` 一旦预先解好文本，就等于替调用方选定了读法——二进制内容被无声地解成一堆替换字符、大响应体被白白解码一次；`data` 与 `raw` 两份状态并存时，「哪个才是真的」也会成为每次读响应时的额外问题。方法入口把选择权交回去，代价只是一次显式调用。

**为什么不自动解析 JSON**（axios 的 `responseType` 在本项目没有对应物；`transformResponse` 的落点是响应拦截器，见 `11-interceptors.md` 的「axios 的 `transformRequest` / `transformResponse` 在这里对应什么」）：`123`、`true`、`"x"` 这些**纯文本本身就是合法 JSON 文本**，靠 `Content-Type` 猜也不可靠（服务端经常不声明或声明错，axios 的 `Auto` 就是在这上面打补丁）。在 TS 里 `any` 把这件事掩盖了，在静态类型下只能把结果塞进变体里让每个调用点 match——要 JSON 的常见场景反而更麻烦，猜错时（文本被解成数字）仍是静默的。所以 `json()` **必须显式调用**，它内部的顺序是「按 `response_encoding` 解码 → `@json.parse`」，解析失败抛 `@json.ParseError`（带出错位置），**不是 `HttpError`**：能拿到 `Response` 说明 HTTP 这一层已经成功，把两类问题混进同一套错误码只会让分类变模糊。要文本要字节、或想自己 `@json.parse(response.text())`，都仍然可以。判断「这到底是不是 JSON」这件事，交给知道上下文的那一层。

写回方向**与读方向同一个编码**：`Response::with_text` / `with_json`（响应拦截器改写响应体用的入口）都按 `response_encoding` 编码，所以 `with_text(response.text())` 是恒等的；哪个编码装不下的码元写成一个 `?`。入口清单与边界见 `11-interceptors.md`。

这张表只在 `Client::request` 上生效——`stream` 交的是原始字节流（`read_all()` 返回 `Bytes`），`sse` 按规范固定 UTF-8 解析事件：流式入口连 `Response` 都没有，解码不是它们的事。实例默认值里带着 `response_encoding` 时，这两个入口照样可用。

## 状态码校验

对应 axios 的 `settle`：

- `validate_status` 为 `None` → 一律放行（axios 里 `!validateStatus` 的效果）；
- 内置默认值是 `200 <= status < 300`，**3xx 也算失败**（axios 不把重定向当成功）；
- 失败时按 axios 的分档给错误码：4xx → `BadRequest`，其余（含 5xx）→ `BadResponse`。

3xx 只在**没有被自动跟随**时才会走到这里，两种情况：`max_redirects <= 0`（显式关掉跟随），或 3xx 没有可用的 `Location`（缺失、空白，或解析不出绝对地址）。那时默认规则把它判成 `BadResponse`，响应（含 `Location`）挂在错误上；要自己处理重定向就用 `with_validate_status(...)` 放行 3xx。跟随规则与上限见 `08-redirects.md`。

校验失败抛出的错误里带着完整响应，调用方可以读服务端返回的错误详情。
