# 03 请求管线

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/client.mbt` | `Client::request` / `Client::stream` / `Client::sse` 的编排：合并 → 定方法 → 发送 →（读全量 / 交还流）→ 解码 → 校验 |
| `src/config/merge.mbt` | 合并契约：四种策略、`merge_config`、`flatten_headers`（为什么在 `config` 包见 `02-config-merge.md`） |
| `src/config/body.mbt` | 请求体的四种形态与序列化：`serialize_body`（字节 + 建议的 `Content-Type`） |
| `src/config/form.mbt` | 表单的 `multipart/form-data` 编码（详见 `07-request-body.md`） |
| `src/util/request.mbt` | 请求侧的纯函数：`resolve_method`、`build_prepared_request`（地址、头、body 的拼装）与只给它用的 `basic_auth` |
| `src/util/response.mbt` | 响应侧的纯函数：`decode_body`、`declares_event_stream`（与只给它用的 `media_type`）、`status_allowed` |
| `src/client.mbt` | 与门面类型接壤的那两个函数：`prepare_request`（把纯函数的 `None` 翻译成 `InvalidUrl` 错误）、`build_response` |
| `src/http_error.mbt` | 错误类型 `ErrorCode` / `ErrorInfo` / `HttpError` 与所有抛错点：`transport_error`、状态码分档 `status_error_code` / `status_error` / `validate_response` |
| `src/url/combine.mbt` | 绝对地址判定、`combine_urls`、`build_full_path` |
| `src/url/build_url.mbt` | `params` → query string |
| `src/url/encode.mbt` | 单个 URL 组件的百分号编码 |
| `src/facade.mbt` | 门面层：`Response`（读全量）/ `StreamResponse`（原始流）/ `SseStream`（事件流）/ `HttpError` 与各子包类型的再导出 |

`util/` 与 `url/` 里的管线函数都是**纯函数**（没有 IO、不涉及异步），可以脱离网络单独测试，`url/url_test.mbt` 就是逐条钉住边界行为的。两者的差别只在依赖：`url/` 连 `Config` 都不认识，`util/` 认识配置与传输层的数据形状（`PreparedRequest`），但不认识任何门面类型。

## 八个步骤

`Client::request(config)` 的顺序与 axios 的 `_request` 对齐：

1. **合并配置**：`merge_config(实例默认值, 请求配置)`（契约见 `02-config-merge.md`）。
2. **确定方法**：合并结果 → 实例默认值 → `Method::Get`。
3. **拼完整地址**：`build_full_path(base_url, url, allow_absolute_urls)`，再 `build_url(url, params)` 追加 query。
4. **拍平头**：`flatten_headers(common_headers, method_headers, headers, method)`，优先级 `common` < 按方法 < 请求级平铺。
5. **取请求体**：`Config::serialize_body()` 给出字节与**建议**的 `Content-Type`（序列化在 `config` 包内完成，见 `07-request-body.md`），有 `auth` 则补 `Authorization`。补默认头一律用 `Headers::set_if_absent`，用户显式设置的同名头永远优先。
6. **发送**：交给 `Transport::send`（契约见 `05-transport.md`）。失败映射见 `04-errors.md`。
7. **读出响应体**：把响应体读到 EOF，字节原样放进 `Response`（解码不在这里，见下）。
8. **校验状态码**：`validate_status` 不通过则抛 `HttpError`。

第 1–5 步是「拼出一份能发出去的请求」，与读不读响应体无关。第 6 步起有三种**读法**，各有自己的入口与返回类型：

| 入口 | 第 6 步之后 | 返回 | 适用 |
|---|---|---|---|
| `Client::request` | 先把响应体读到 EOF（`ResponseBody::read_all_partial`），再校验状态码 | `Response` | 常规请求，需要完整响应体 |
| `Client::stream` | 直接把响应头与响应体流交出去 | `StreamResponse` | 大文件下载、自己按块处理 |
| `Client::sse` | 交出去，但要求响应头声明了 `text/event-stream` | `SseStream` | 按事件读 SSE |

**读法由入口决定，不由配置决定。** `response_encoding` 只描述「字节怎么解成文本」，不描述读不读——「读完还是流」是调哪个方法决定的，配置字段里没法表达，也不该表达。语言层面同样没法让一个方法的返回类型随运行时配置变化：真要那样只能返回一个变体包装，调用方每次都得 match。三种读法静态分开之后，「调错了」是编译错误，不需要运行时守卫。

`Response` 拿到手之后，**怎么读**同样由方法决定，这是第二层「读法」：`text()`（按 `response_encoding` 解码）、`bytes()`（精确字节）、`json()`（先解码再 `@json.parse`）。三层入口 × 三种读法都是静态的，不存在「配置变了返回类型就变」的情况。

三种入口的**前半段与状态码校验完全一致**（`stream` 与 `sse` 共用 `Client::open_stream`，规则见 `status_allowed` / `status_error_code`）。差别只在失败时拿什么：`request` 报错时带的是完整响应，两个流式入口报错前会把错误体读完（不猜它是 JSON 还是别的什么格式——错误体格式不可预期，强行解释只会把「状态码失败」这个更准确的原因盖掉），字节放在 `HttpError::response()` 的 `Response` 上，按需要读成文本（`text()`）或原样取走（`bytes()`）。流式路径的超时语义见 `05-transport.md`，SSE 另见 `06-sse.md`。

**失败不等于什么都没收到**：响应头到手之后才可能开始读响应体，所以读取阶段的任何失败（单次读取超时、连接被重置）都已经晚于响应头——三个入口都会把**已经收到的响应**挂到错误上（状态行、响应头，以及失败前读到的部分正文，`Client::request` 与 `StreamResponse::read_all` 都用了 `read_all_partial` 保住那半截）。响应头到手之前就失败（连不上、DNS、缺 url）时错误里没有响应。判定与字段含义见 `04-errors.md`。

## URL 拼接规则

### 绝对地址判定

等价于 axios 的 `/^([a-z][a-z\d+\-.]*:)?\/\//i`：

- `https://a.com/x`、`http://a.com` → 绝对；
- `//cdn.example.com/x` → **算绝对地址**（scheme 部分可选，这是 axios 正则的真实行为）；
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

**为什么不自动解析 JSON**（axios 的 `responseType` / `transformResponse` 在本项目没有对应物）：`123`、`true`、`"x"` 这些**纯文本本身就是合法 JSON 文本**，靠 `Content-Type` 猜也不可靠（服务端经常不声明或声明错，axios 的 `Auto` 就是在这上面打补丁）。在 TS 里 `any` 把这件事掩盖了，在静态类型下只能把结果塞进变体里让每个调用点 match——要 JSON 的常见场景反而更麻烦，猜错时（文本被解成数字）仍是静默的。所以 `json()` **必须显式调用**，它内部的顺序是「按 `response_encoding` 解码 → `@json.parse`」，解析失败抛 `@json.ParseError`（带出错位置），**不是 `HttpError`**：能拿到 `Response` 说明 HTTP 这一层已经成功，把两类问题混进同一套错误码只会让分类变模糊。要文本要字节、或想自己 `@json.parse(response.text())`，都仍然可以。判断「这到底是不是 JSON」这件事，交给知道上下文的那一层。

这张表只在 `Client::request` 上生效——`stream` 交的是原始字节流（`read_all()` 返回 `Bytes`），`sse` 按规范固定 UTF-8 解析事件：流式入口连 `Response` 都没有，解码不是它们的事。实例默认值里带着 `response_encoding` 时，这两个入口照样可用。

## 状态码校验

对应 axios 的 `settle`：

- `validate_status` 为 `None` → 一律放行（axios 里 `!validateStatus` 的效果）；
- 内置默认值是 `200 <= status < 300`，**3xx 也算失败**（axios 不把重定向当成功）；
- 失败时按 axios 的分档给错误码：4xx → `BadRequest`，其余（含 5xx）→ `BadResponse`。

校验失败抛出的错误里带着完整响应，调用方可以读服务端返回的错误详情。
