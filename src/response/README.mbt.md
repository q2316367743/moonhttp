# response —— 读全量的响应值

`Response` 对应 axios 的 `AxiosResponse`：状态行、响应头、触发它的配置，以及**未经解码的原始字节**。它不抛 `HttpError`——能拿到 `Response` 就说明 HTTP 这一层已经成功（状态码校验在 `client` 包的管线上）；怎么读由方法决定，没有「默认解码」。

```toml
import {
  "q2316367743/moonhttp/response",
}
```

通常不必直接 import 本包：根包 `@moonhttp` 已把 `Response` 再导出。

## 读法

| 方法 | 说明 |
|---|---|
| `bytes()` | 原始响应字节，不解码（二进制内容、想自己按别的编码解时用） |
| `text()` | 按 `config.response_encoding` 解成文本；解码一律 lossy（坏字节 → `U+FFFD`），不抛错 |
| `json()` | 先按 `text()` 解码再 `@json.parse`；解析失败抛 `@json.ParseError`，**不是** `HttpError` |
| `content_length()` | 响应体字节长度，等价 `bytes().length()` |
| `is_success()` | 状态码是否 2xx（给自定义了 `validate_status` 放行 3xx/4xx 的场景用） |

## 改写入口（供响应拦截器）

| 方法 | 说明 |
|---|---|
| `with_status(status)` | 换状态码（不重跑状态码校验） |
| `with_headers(headers)` | 整体替换响应头 |
| `with_body(bytes)` | 换响应体字节 |
| `with_text(text)` | 换响应体文本，按 `response_encoding` 编码——与 `text()` 读方向对称，`with_text(response.text())` 恒等 |
| `with_json(json)` | 换 JSON 载荷（写回的是 JSON 文档：`Json::String("x")` 写成 `"x"` 带引号） |

五个方法都返回新值（`Response` 是不可变值），都不改响应头里的 `Content-Length`。

## 用法

```moonbit nocheck
let resp = api.get("/user/1")
println(resp.status) // 200
let user = resp.json()
println(resp.text())
```

`raw` 字段私有、跨包构造只有 `Response::new` 一个口（`client` 包拼响应走它）：这是为了让「怎么读」只有一个落点，`response_encoding` 才不会名存实亡。

实现取舍见
[`docs/01-architecture.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/01-architecture.md)。
