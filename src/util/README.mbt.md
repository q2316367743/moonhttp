# util —— 纯函数层

根包与 `transport` 之间的变换层：把合并好的 `Config` 加工成一份可直接发送的 `PreparedRequest`、判定状态码、解码响应体。没有 IO，签名里也没有门面类型。

## 准入条件

往里加东西前先看这一条：函数必须是**纯的**，且签名里不出现 `Response` / `StreamResponse` / `SseStream` / `HttpError` / `ErrorCode`——失败用 `Option` 表达，翻译成哪个 `ErrorCode` 由根包决定。分层理由见
[`docs/01-architecture.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/01-architecture.md)。

```toml
import {
  "q2316367743/moonhttp/util",
}
```

## API

| 函数 | 说明 |
|---|---|
| `build_prepared_request(config)` | 把一份合并好的配置加工成可发送的请求：完整地址与 query、拍平后的头、请求体与建议的 `Content-Type`、认证与代理凭据。**两类输入返回 `None`**：地址不可用（缺 `url` 且缺 `base_url`，或 `url` 非法），以及配了代理却没给 host |
| `status_allowed(status, config)` | 状态码是否通过校验；`validate_status` 缺省时按 2xx |
| `resolve_method(请求级?, 实例默认?)` | 方法回退顺序：请求级 → 实例默认值 → `GET` |
| `decode_body(bytes, encoding)` | 按编码解码成文本，一律 lossy（非法字节 → `U+FFFD`），不抛错 |
| `encode_body(text, encoding)` | 反向写回字节，同样 lossy；供 `Response::with_text` / `with_json` 改写响应体时用 |
| `declares_event_stream(headers)` | 响应头是否声明了 `text/event-stream` |

## 补默认值的口径

`build_prepared_request` 补 `Content-Type` / `Authorization` / `Accept` 之类一律用 `set_if_absent`：调用方显式设置的同名头永远优先。代理凭据不会写进目标请求头。
