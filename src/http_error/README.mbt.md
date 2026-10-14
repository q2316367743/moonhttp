# http_error —— 对外的错误契约

`HttpError` / `ErrorInfo` / `ErrorCode` 与全部访问器。本包是**纯契约**：只定义错误长什么样；「什么情况下造错误」全在 `client` 包（造错误是编排层的行为），因此本包连传输层都不依赖。

```toml
import {
  "q2316367743/moonhttp/http_error",
}
```

通常不必直接 import 本包：根包 `@moonhttp` 已把三个类型再导出。

## `HttpError`

| 方法 | 说明 |
|---|---|
| `code()` | 错误分类（`ErrorCode`） |
| `message()` | 面向人的错误描述 |
| `config()` | 触发错误的配置（已完成合并），便于定位是哪一项配置不对 |
| `response()` | 已经收到的响应：状态码校验失败时是完整响应；传输层失败发生在响应头之后时是失败前的部分（响应体可能只有半截）；连响应头都没收到时 `None` |
| `is_cancelled()` | 是否被取消信号叫停（对应 axios 的 `axios.isCancel`） |
| `new(message, code, config)` | 不带响应地造一个错误——给请求拦截器主动中止请求用 |

## 解构的写法

`pub using` 能再导出类型，但再导出不了构造器，所以构造器模式要写**类型限定**的形式：

```moonbit nocheck
try {
  ignore(api.request(config))
} catch {
  @moonhttp.HttpError::HttpError(info) => {
    println(info.code)
    println(info.message)
  }
}
```

不想解构时用访问器更顺手：`catch { error => error.code() }`。

## `ErrorCode`

`BadRequest`（4xx）/ `BadResponse`（5xx 及被拒状态码）/ `Network` / `Timeout` / `InvalidUrl` / `NotSupported` / `Cancelled` / `TooManyRedirects`。`to_string()` 渲染成 axios 风格错误码字符串（`ERR_BAD_REQUEST`、`ECONNABORTED`、`ERR_CANCELED` 等），`Show` 实现与它一致。

错误契约的完整说明见
[`docs/04-errors.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/04-errors.md)。
