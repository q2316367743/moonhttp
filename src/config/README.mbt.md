# config —— 请求配置

`Config` 描述「一个请求长什么样」：地址、方法、超时、请求头、查询参数、请求体、认证、代理、进度回调、取消句柄。实例默认值（`Client` 里那份）与本次请求的配置都是它，两者的合并规则也在本包（`merge_config`）。

本包是**纯逻辑**包：不依赖 async 运行时，合并语义与请求体字节都能用同步测试钉死。依赖 `headers`（头集合）与 `url`（复用 query 序列化器），不反向依赖本模块的任何包。

```toml
import {
  "q2316367743/moonhttp/config",
}
```

## 怎么造一份配置

```moonbit nocheck
///|
let config = Config::new("/users") // 带 url 起步

///|
let defaults = Config::default() // 从零起步
  .with_base_url("https://api.example.com")
  .with_timeout(5_000)
```

`Config` 的**请求体是私有字段**，所以包外写不出记录字面量 / 记录展开——构造只能走上面两个入口加 `with_*`。这样「请求体」与它配套的 `Content-Type` 不会被拆散，往结构体加字段忘了配合并策略也会变成编译错误。

方法字段叫 `http_method` 而不是 `method`（`method` 是 MoonBit 保留字），构建器仍叫 `with_method`。

## 构建器：23 个 `with_*`

**地址与方法**

| 方法 | 说明 |
|---|---|
| `with_url(url)` | 请求地址：相对地址与 `base_url` 拼接，绝对地址直连 |
| `with_base_url(url)` | 基地址，通常写在实例默认值里 |
| `with_method(Method)` | 请求方法，缺省回退到 `GET` |
| `with_allow_absolute_urls(bool)` | 是否允许绝对地址直连（默认 `true`） |

**超时与重定向**

| 方法 | 说明 |
|---|---|
| `with_timeout(ms)` | 超时毫秒数，`0` 表示不超时（默认） |
| `with_max_redirects(n)` | 最多跟几跳重定向，默认 5，`0` 表示不跟随 |

**请求头**

| 方法 | 说明 |
|---|---|
| `with_header(name, value)` | 本次请求的头 |
| `with_headers(Headers)` | 一次性给一组头 |
| `with_common_header(name, value)` | 公共头：该实例的所有方法都带上 |
| `with_method_header(Method, name, value)` | 按方法区分的头（如只给 `Post` 加 `Content-Type`） |

三层优先级：`common_headers` < `method_headers` < 请求级 `headers`，逐层覆盖（头名大小写不敏感）。

**查询参数**

| 方法 | 说明 |
|---|---|
| `with_params(Json)` | 查询参数，数组与嵌套对象按括号约定展开 |
| `with_params_serializer(fn(Json) -> String)` | 整体替换「params → query 文本」这一步（只作用于 URL 的 query） |

**请求体**

| 方法 | 说明 | 自动补的 `Content-Type` |
|---|---|---|
| `with_data_from_str(String)` | 原样 UTF-8 字节 | 不补 |
| `with_data_from_json(Json)` | `stringify()` 后的 JSON 文本 | `application/json` |
| `with_data_from_urlencoded(Json)` | `a=1&b=2` | `application/x-www-form-urlencoded` |
| `with_data_from_form(FormData)` | multipart 正文 | `multipart/form-data; boundary=...` |

补头一律是 `set_if_absent`：你自己设了同名头就一个字节都不改。

**认证与代理**

| 方法 | 说明 |
|---|---|
| `with_auth(username, password)` | Basic 认证，落成 `Authorization` 头 |
| `with_proxy(host, port?, protocol?, username?, password?)` | 代理；凭据只落在建隧道的 `CONNECT` 上，不发给目标服务器 |

**进度与取消**

| 方法 | 说明 |
|---|---|
| `with_on_upload_progress(cb)` | 上传进度回调（同步、不抛错） |
| `with_on_download_progress(cb)` | 下载进度回调 |
| `with_cancel_token(CancelToken)` | 绑定取消句柄 |

**响应处理**

| 方法 | 说明 |
|---|---|
| `with_response_encoding(ResponseEncoding)` | 响应体按什么解码，默认 `Utf8` |
| `with_validate_status(fn(Int) -> Bool)` | 状态码校验规则，默认「2xx 算成功」 |

## Config 的其它方法

| 方法 | 说明 |
|---|---|
| `Config::new(url)` / `Config::default()` | 构造 |
| `serialize_body()` | 请求体 → 字节 + 建议的 `Content-Type`（`SerializedBody`） |
| `next_redirect(location, status, method?)` | 算重定向的下一跳配置（方法、请求体、凭据、`Host` 的改写规则） |
| `to_string()` / `output(logger)` / `to_repr()` | 渲染（`Show` / `Debug`） |

## 配套类型

| 类型 | 说明 |
|---|---|
| `Method` | `Get` / `Head` / `Post` / `Put` / `Delete` / `Connect` / `Options` / `Trace` / `Patch`，另有 `Method::parse(view)` |
| `ResponseEncoding` | `Utf8`（默认）/ `Latin1` / `Ascii` / `Utf16le` |
| `Auth` | `{ username?, password? }`，Basic 凭据 |
| `Proxy` / `ProxyProtocol` | `{ protocol?, host?, port?, auth? }`；`Proxy::is_usable()` 判断「配了代理但没给 host」 |
| `FormData` / `FormValue` / `FormFile` | `new()` / `append_text(name, value)` / `append_file(name, filename, bytes, content_type?)` / `entries()` / `length()` |
| `CancelToken` | `new()` / `cancel(message?)` / `is_cancelled()` / `reason()` / `attach(cb)` / `detach(id)` |
| `ProgressEvent` / `ProgressCallback` | `{ loaded, total? }` + `progress()`（total 未知或为 0 时给 `None`） |
| `SerializedBody` | `{ bytes?, content_type? }` |

## 包级函数

| 函数 | 说明 |
|---|---|
| `defaults()` | 内置默认值：`timeout = 0`（不超时）、`max_redirects = 5`、`response_encoding = Utf8`、`validate_status` = 2xx、`Accept: application/json, text/plain, */*`、`allow_absolute_urls = true` |
| `merge_config(默认值, 请求级)` | 请求级配置合并在实例默认值之上 |
| `flatten_headers(公共头?, 按方法的头?, 请求级头?, 方法)` | 三层头拍平成一份 |
| `merge_json(a, b)` / `merge_json_option(a, b)` | JSON 深合并（`params` 用它） |

## 合并策略

字段各归属一档，`None` 一律表示「未提供」→ 回退，而不是覆盖：

| 字段 | 策略 |
|---|---|
| `url` / `http_method` / 请求体 | 只取请求级 |
| `base_url` / `timeout` / `max_redirects` / `response_encoding` / 进度回调 / `cancel_token` | 请求级优先，缺省回退实例默认值 |
| `params` / `headers` / `auth` / `proxy` | 逐层深合并（数组整体替换，函数没法合并所以整体接管） |
| `validate_status` / `params_serializer` | 请求级提供即整体接管 |

合并、请求体字节布局与重定向改写规则的完整说明见
[`docs/02-config-merge.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/02-config-merge.md)
与 [`docs/07-request-body.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/07-request-body.md)。
