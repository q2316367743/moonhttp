# 04 错误契约

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/facade.mbt` | `ErrorCode` / `ErrorInfo` / `HttpError` 与访问器（根包门面层，与响应类型同一文件） |
| `src/client.mbt` | `validate_response`（状态码校验）与 `try_parse_json`（强制 JSON 失败），与入口同文件 |
| `src/client.mbt` | 把 `TransportError` 翻译成 `ErrorCode` |
| `src/error_test.mbt` | 错误路径的端到端用例 |

## 类型形状

```moonbit
pub(all) struct ErrorInfo {
  message : String        // 面向人的描述
  code : ErrorCode        // 分类
  config : Config         // 已合并的配置（排查用）
  response : Response?    // 服务端已响应却没通过校验时的原始响应
}

pub(all) suberror HttpError {
  HttpError(ErrorInfo)
}
```

访问器：`HttpError::code()` / `message()` / `response()` / `config()` / `info()` / `to_string()`。

两点设计取舍：

- **`ErrorInfo` 单独成一个结构体**而不是把字段平铺在 `suberror` 上：MoonBit 的 suberror 构造子用位置参数最稳，包一层结构体后新增字段不需要改所有构造点，也让访问器实现干净。
- **`pub(all) suberror`**：不带 `(all)` 时构造子不导出，使用方就只能拿到错误、无法按分类匹配。

## `ErrorCode` 与 axios 的对应

| 本项目 | axios 错误码字符串 | 触发点 |
|---|---|---|
| `BadRequest` | `ERR_BAD_REQUEST` | `validate_response`：状态码 4xx |
| `BadResponse` | `ERR_BAD_RESPONSE` | `validate_response`：其它非 2xx（含 5xx、3xx）；`build_response`：`response_type = Json` 但解析失败 |
| `Network` | `ERR_NETWORK` | `Client::request`：`TransportError::Network`（连接失败、DNS、TLS 等） |
| `Timeout` | `ECONNABORTED` | `Client::request`：`TransportError::Timeout` |
| `InvalidUrl` | `ERR_INVALID_URL` | `build_prepared_request`：既没有 `url` 也没有可用的 `base_url` |
| `NotSupported` | `ERR_NOT_SUPPORT` | `Client::request`：`TransportError::Unsupported`（传输层做不到，例如相对地址）；`Client::sse`：响应头没有声明 `text/event-stream`（拿到的不是 SSE 却要按事件读，见 `06-sse.md`）——报错前会先关掉连接 |

关于超时用的是 `ECONNABORTED` 而不是 `ETIMEDOUT`：axios 默认就是前者，只有打开 `transitional.clarifyTimeoutError` 时才换成后者。这里保持默认行为。

状态码分档是复刻 axios 的 `[ERR_BAD_REQUEST, ERR_BAD_RESPONSE][floor(status / 100) - 4]`：按百位取档，4xx 一档、其它一档。写成显式判断是为了让源码可读。

## 错误里带什么

| 字段 | 什么时候有值 |
|---|---|
| `config` | 永远有（已合并的配置），可用于回答「到底是哪一层配置不对」 |
| `response` | 状态码校验失败、以及强制 JSON 解析失败时；本地失败（如缺 url）与传输层失败时为 `None` |

## 错误是怎样跨层传播的

```
底层 HTTP 实现（moonbitlang/async）
        ↓ 任意错误
TransportError { Timeout | Network(String) | Unsupported(String) }   ← src/transport/
        ↓ Client::request 做一次映射
ErrorCode { Timeout | Network | NotSupported | ... }                 ← src/
```

中间加了一层 `TransportError` 的目的：让上层**不需要认识异步库的错误类型**。`Client::request` 只需要 `catch` 三个构造子；自定义传输实现也只需要把自己的错误归到这三类里，不必知道底层用的是哪套 HTTP 库。

## 新增一个错误分类的步骤

1. `src/facade.mbt` 的 `ErrorCode` 加构造子（并补 `to_string` 映射与 axios 错误码字符串）；
2. 在触发点调用 `make_error(message, code, config, response)` 后 `raise`；
3. 若是传输层能提前识别的失败，考虑先在 `TransportError` 里加一类；
4. `src/error_test.mbt` 补用例；
5. 更新本文件与 `docs/README.md` 的索引说明（如果涉及读法变化）。
