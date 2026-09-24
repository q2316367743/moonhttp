# 04 错误契约

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/http_error.mbt` | 错误契约的全部：`ErrorCode` / `ErrorInfo` / `HttpError` 与访问器，加上**所有**构造它们的地方（`make_error`、`transport_error`、`status_error` / `validate_response`、`too_many_redirects_error`） |
| `src/util/response.mbt` | `status_allowed`：状态码是否被配置放行的**纯**判定（不构造错误，所以能待在根包外） |
| `src/transport/stream.mbt` | `ResponseBody::read_all_partial`：读到一半失败时交出已读到的字节 |
| `src/error_test.mbt` | 错误路径的端到端用例（含本机 server 的「中途超时」用例） |

## 类型形状

```moonbit
pub(all) struct ErrorInfo {
  message : String        // 面向人的描述
  code : ErrorCode        // 分类
  config : Config         // 已合并的配置（排查用）
  response : Response?    // 已经收到的响应（见下）
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
| `BadResponse` | `ERR_BAD_RESPONSE` | `validate_response`：其它非 2xx（含 5xx、3xx） |
| `Network` | `ERR_NETWORK` | `TransportError::Network`（连接失败、DNS、TLS；**读响应体中途**连接被重置也算） |
| `Timeout` | `ECONNABORTED` | `TransportError::Timeout`（含读响应体中途的单次读取超时） |
| `InvalidUrl` | `ERR_INVALID_URL` | `build_prepared_request`（`src/util/request.mbt`）返回 `None`：既没有 `url` 也没有可用的 `base_url`；由根包 `prepare_request` 翻译成 `HttpError` |
| `NotSupported` | `ERR_NOT_SUPPORT` | `TransportError::Unsupported`（传输层做不到，例如相对地址、重定向到非 http(s) 协议）；`Client::sse`：响应头没有声明 `text/event-stream`（拿到的不是 SSE 却要按事件读，见 `06-sse.md`）——报错前会先关掉连接 |
| `TooManyRedirects` | `ERR_FR_TOO_MANY_REDIRECTS` | `Client::send_following_redirects`：重定向次数超过 `max_redirects`（默认 5，见 `08-redirects.md`） |

关于超时用的是 `ECONNABORTED` 而不是 `ETIMEDOUT`：axios 默认就是前者，只有打开 `transitional.clarifyTimeoutError` 时才换成后者。这里保持默认行为。

重定向上限用的是 `ERR_FR_TOO_MANY_REDIRECTS`：axios 直接透传 follow-redirects 的这个错误码（`AxiosError` 里也定义了这个常量），跟着用同一个字符串，调用方按码分支时不必区分是哪一家的实现。与 axios 的一点不同：这个错误里**有**响应（最后一个 3xx），见下表。

状态码分档是复刻 axios 的 `[ERR_BAD_REQUEST, ERR_BAD_RESPONSE][floor(status / 100) - 4]`：按百位取档，4xx 一档、其它一档。写成显式判断是为了让源码可读。

**错误码永远是「失败本身」的分类**：读响应体读到一半超时 → `Timeout`，中途断连 → `Network`，不会因为此时状态码是 500 就改报 `BadResponse`。状态码与响应头在 `response` 里看得到，两件事不混在一起。

## 错误里带什么

**没有通过校验**和**失败在中途**是两件事，它们都可能带响应，区别只在响应完整不完整：

| 场景 | `response` |
|---|---|
| 状态码没通过 `validate_status` | **完整响应**：三个入口都会先把错误体读完，字节原样放在 `Response` 里（要文本按 `response_encoding` 调 `text()`，要原样调 `bytes()`），错误体内容不额外解释 |
| 传输层失败发生在**响应头到手之后**（读响应体时超时、断连） | 已经收到的部分：状态行与响应头一定在，响应体字节是**失败前读到的部分**（`bytes()` / `text()` 拿到的可能只有半截） |
| 重定向次数超过 `max_redirects` | **最后那个 3xx 响应**（用 `read_all_partial` 读，正文可能是半截）：`Location` 与状态码都在里面，重定向成环时这是最直接的现场。axios 的同一个错误里没有响应 |
| 本地失败（缺 url、传输层不支持）与响应头到手之前的传输层失败（连不上、DNS 失败） | `None`——那时确实没有响应 |

| 字段 | 什么时候有值 |
|---|---|
| `config` | 永远有（已合并的配置），可用于回答「到底是哪一层配置不对」 |
| `response` | 见上表 |

### 为什么失败也要带响应

传输层失败不等于「什么都没收到」。请求是分两段完成的——**响应头**到手之后才开始读**响应体**，第二段里的任何失败（单次读取超时、连接被重置）都已经晚于第一段：

- 状态码、响应头早就在手里，丢掉它们等于让调用方在失败时看不到「服务器到底回了什么」；
- 服务端的错误正文常常已经到了一部分（`{"error": "too many ...` 这种），那半截正是排查问题最直接的线索；
- 所以 `ResponseBody::read_all_partial` 中途失败时**不丢掉已读到的字节**，上层把它们拼成一份响应挂到错误上（`bytes()` / `text()` 拿到的可能就是半截的）。

`Client::sse` 的准入检查是这条规则的一个例外：错误里挂着状态行与响应头，但**不读 body**——声明了别的类型就可能是任意大小的二进制，要看原文请改用 `Client::stream`（见 `06-sse.md`）。

错误码不受影响：它仍然说「失败是什么」（`Timeout` / `Network`），`response` 说「已经收到什么」。这两条信息缺一不可，所以分开表达。

## 错误是怎样跨层传播的

```
底层 HTTP 实现（moonbitlang/async）
        ↓ 任意错误
TransportError { Timeout | Network(String) | Unsupported(String) }   ← src/transport/
        ↓ Client::request 做一次映射（顺带挂上已经收到的响应）
ErrorCode { Timeout | Network | NotSupported | ... }                 ← src/
```

中间加了一层 `TransportError` 的目的：让上层**不需要认识异步库的错误类型**。`Client::request` 只需要 `catch` 三个构造子；自定义传输实现也只需要把自己的错误归到这三类里，不必知道底层用的是哪套 HTTP 库。

「已经收到的响应」跨的是另一层：传输层只管把字节交出来（`RawResponse` / `read_all_partial`），拼成对外的 `Response`、挂到错误上是根包的事——传输层不认识 `Response`。

## 新增一个错误分类的步骤

1. `src/http_error.mbt` 的 `ErrorCode` 加构造子（并补 `to_string` 映射与 axios 错误码字符串）；
2. 在触发点调用 `make_error(message, code, config, response)` 后 `raise`——`response` 传**当时已经收到的响应**，没有就传 `None`；同一份文案只有一个落点时，按 `status_error` / `too_many_redirects_error` 的样子抽一个专用构造器；
3. 若是传输层能提前识别的失败，考虑先在 `TransportError` 里加一类；
4. `src/error_test.mbt` 补用例（错误码字符串的契约表在 `error code rendering covers every category`）；
5. 更新本文件与 `docs/README.md` 的索引说明（如果涉及读法变化）。
