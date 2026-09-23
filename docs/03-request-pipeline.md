# 03 请求管线

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/client.mbt` | `Client::request` 的编排：合并 → 定方法 → 发送 → 解析 → 校验 |
| `src/pipeline.mbt` | 管线里的三个纯函数：`build_prepared_request` / `build_response` / `validate_response` |
| `src/url/combine.mbt` | 绝对地址判定、`combine_urls`、`build_full_path` |
| `src/url/build_url.mbt` | `params` → query string |
| `src/url/encode.mbt` | 单个 URL 组件的百分号编码 |
| `src/response.mbt` | `Response` 类型与 `text()` / `is_success()` |

`pipeline.mbt` 与 `url/` 都是**纯函数**（没有 IO、不涉及异步），可以脱离网络单独测试，`url/url_test.mbt` 就是逐条钉住边界行为的。

## 八个步骤

`Client::request(config)` 的顺序与 axios 的 `_request` 对齐：

1. **合并配置**：`merge_config(实例默认值, 请求配置)`（契约见 `02-config-merge.md`）。
2. **确定方法**：合并结果 → 实例默认值 → `Method::Get`。
3. **拼完整地址**：`build_full_path(base_url, url, allow_absolute_urls)`，再 `build_url(url, params)` 追加 query。
4. **拍平头**：`flatten_headers(common_headers, method_headers, headers, method)`，优先级 `common` < 按方法 < 请求级平铺。
5. **序列化 body**：`Json::String` 原样发送；其它 JSON 值 `stringify()` 并补 `Content-Type: application/json`；有 `auth` 则补 `Authorization`。补默认头一律用 `Headers::set_if_absent`，用户显式设置的同名头永远优先。
6. **发送**：交给 `Transport::send`（契约见 `05-transport.md`）。失败映射见 `04-errors.md`。
7. **解析响应体**：按 `response_type` 处理（见下）。
8. **校验状态码**：`validate_status` 不通过则抛 `HttpError`。

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

| `data` 的取值 | 发送内容 | 自动补的头 |
|---|---|---|
| `None` | 不带 body | — |
| `Json::String(s)` | `s` 的 UTF-8 字节，原样 | 不推断类型 |
| 其它 `Json` 值 | `stringify()` 后的 UTF-8 字节 | `Content-Type: application/json` |

`auth` 有值时补 `Authorization: Basic base64(username:password)`，缺一半的用户名/密码按空串处理。

**补头一律用 `set_if_absent`**：用户显式设置的同名头永远优先。这条由 `src/request_test.mbt` 的两个用例守着（"json body sets content type only when absent"、"auth produces basic authorization header" 的第二个断言）。

## 响应体解析

| `response_type` | 行为 |
|---|---|
| `Auto`（默认） | 尝试 `@json.parse`；**失败不报错**，把原文包成 `Json::String` 交给调用方（等价于 axios 的 `forcedJSONParsing`） |
| `Json` | 强制解析；失败抛 `HttpError(BadResponse)`，并把「data 为原文」的响应挂在错误上 |
| `Text` | 完全不解析，`data` 就是 `Json::String(原文)` |

原始字节始终保留在 `Response::raw`，文本用 `Response::text()`（`decode_lossy`，非法 UTF-8 不抛错）。当前实现统一用 UTF-8 解码，不做 charset 探测。

## 状态码校验

对应 axios 的 `settle`：

- `validate_status` 为 `None` → 一律放行（axios 里 `!validateStatus` 的效果）；
- 内置默认值是 `200 <= status < 300`，**3xx 也算失败**（axios 不把重定向当成功）；
- 失败时按 axios 的分档给错误码：4xx → `BadRequest`，其余（含 5xx）→ `BadResponse`。

校验失败抛出的错误里带着完整响应，调用方可以读服务端返回的错误详情。
