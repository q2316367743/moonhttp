# util —— 纯函数层

根包与 `transport` 之间的变换层：把合并好的 `Config` 加工成一份可直接发送的 `PreparedRequest`、判定状态码、解码响应体。**没有 IO，签名里也没有门面类型。**

## 准入条件

往里加东西前先看这一条：函数必须是**纯的**，且签名里不出现 `Response` / `StreamResponse` / `SseStream` / `HttpError` / `ErrorCode`。根包 import 本包，本包一旦反过来需要这些门面类型就成环——所以「构造响应」与「抛 `HttpError`」必须留在根包，这里只留它们依赖的纯变换。失败用 `Option` 表达，翻译成哪个 `ErrorCode` 由根包决定。

```toml
import {
  "q2316367743/moonhttp/util",
}
```

## API

| 函数 | 说明 |
|---|---|
| `build_prepared_request(config)` | 拼完整地址并追加 query → 拍平三层头（common < 按方法 < 请求级）→ 落请求体与建议的 `Content-Type` → 给 `auth` 补 `Authorization` → 把 `Proxy-Authorization` 挪到 CONNECT 上。**两类输入返回 `None`**：地址不可用（缺 `url` 且缺 `base_url`，或 `url` 非法），以及配了代理却没给 host |
| `status_allowed(status, config)` | 状态码是否通过校验；`validate_status` 缺省时按 2xx。判定是纯的——流式路径响应体还没读，要能先判 |
| `resolve_method(请求级?, 实例默认?)` | 方法回退顺序：请求级 → 实例默认值 → `GET` |
| `decode_body(bytes, encoding)` | 按编码解码成文本，一律 lossy（非法字节 → `U+FFFD`），不抛错 |
| `encode_body(text, encoding)` | 反向写回字节，同样 lossy；供 `Response::with_text` / `with_json` 改写响应体时用 |
| `declares_event_stream(headers)` | 响应头是否声明了 `text/event-stream`（`Client::sse` 的准入检查与 `StreamResponse::is_event_stream` 共用这一处判定） |

## 补默认值的口径

`build_prepared_request` 补 `Content-Type` / `Authorization` / `Accept` 之类一律用 `set_if_absent`：调用方显式设置的同名头永远优先，库不会覆盖。代理凭据不进目标请求头——它只用于建立隧道，发给目标服务器既是泄漏也无用处。

## 测试

本包没有自己的 `_test.mbt`：里面的函数由根包的黑盒测试端到端覆盖（编码用 `src/encoding_test.mbt`、拼请求与错误分档用 `src/request_test.mbt`、方法回退用 `src/moonhttp_test.mbt`）。分层理由见
[`docs/01-architecture.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/01-architecture.md)。
