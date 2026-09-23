# 05 传输层契约

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/transport/transport.mbt` | `Transport` trait、`PreparedRequest`、`RawResponse`、`TransportError` |
| `src/transport/async_http.mbt` | 真实实现（唯一依赖 `moonbitlang/async` 的文件） |
| `src/transport/mock.mbt` | 测试用实现：记录请求、按队列返回响应、可注入失败 |
| `src/transport/transport_test.mbt` | 传输层自身的用例（含不依赖外网的真实实现用例） |

## 契约

```moonbit
pub(open) trait Transport {
  async fn send(Self, PreparedRequest) -> RawResponse raise TransportError
}
```

`PreparedRequest` 是**已经做完所有配置语义加工**的请求，字段含义：

| 字段 | 含义 |
|---|---|
| `http_method` | 最终方法（缺省回退已完成） |
| `url` | 完整地址，已含 `base_url` 拼接结果与序列化后的 query |
| `headers` | 已按 `common` < 按方法 < 请求级平铺 拍平、且已补过 `Content-Type` / `Authorization` 的最终头集合 |
| `body` | 请求体字节；`None` 表示不带 body |
| `timeout` | 超时毫秒数；`None` 或 `<= 0` 表示不限时 |

`RawResponse` 是**纯传输结果**，刻意不叫 `Response`（上层的 `Response` 还要承担 JSON 解析与状态码校验）：

| 字段 | 含义 |
|---|---|
| `status` | HTTP 状态码 |
| `status_text` | 原因短语 |
| `headers` | 响应头（本项目自己的 `Headers`，大小写不敏感） |
| `body` | 完整响应体字节 |

`TransportError` 只有三类：`Timeout` / `Network(String)` / `Unsupported(String)`。分类的用途见 `04-errors.md`。

## 写一个自定义实现

```moonbit
pub impl Transport for MyTransport with fn send(self, request) {
  let body = match request.body {
    Some(bytes) => bytes
    None => b""
  }
  {
    status: 200,
    status_text: "OK",
    headers: Headers::new().set("Content-Type", "application/json"),
    body,
  }
}
```

### 注意事项

1. **实现里的方法写 `fn` 而不是 `async fn`**。异步性是 trait 声明的一部分，`impl` 侧不重复标注；写成 `async fn` 会报语法错误。这与 `moonbitlang/async` 自身的写法一致（它的 `pub impl @io.Reader for Client with fn _direct_read(...)` 对应的 trait 方法就是 `async fn`）。
2. **`impl` 前要写 `pub`**，否则外部包看不到这个实现，无法把它当作 `&Transport` 使用。
3. **还要补一条 `pub extend`**：`pub extend MyTransport with Transport::{send}`，否则会收到「trait impl 隐式挂成常规方法」的废弃告警。
4. `&Transport` 特质对象的异步方法可以直接调用（底层实现是「结构体里存 `&Trait` 字段 + 异步调用」，`moonbitlang/async` 的 `parser.mbt` 就是这么写的）。

## `AsyncHttpTransport` 的实现细节

真实实现包在 `moonbitlang/async/http` 的便捷函数 `@http.request(uri, method, headers, body)` 上，做了三件适配：

1. **枚举映射**：本项目的 `Method` 与底层的 `RequestMethod` 一一对应（`to_request_method`）。上层不认识底层类型，所以映射写在这里。
2. **头的容器转换**：底层要求 `Map[CaseInsensitiveString, String]`（`to_http_headers` / `from_http_headers`）。两边都是大小写不敏感的容器，转换只搬类型不改语义。
3. **超时与错误收敛**：`timeout > 0` 时用 `@async.with_timeout` 包裹；底层抛的 `TimeoutError` 映射成 `TransportError::Timeout`，其余错误统一归到 `Network` 并保留原始错误文本。

### 尚未处理的能力（改动时的落点）

| 能力 | 现状 | 可能的实现方式 |
|---|---|---|
| 连接复用 | 每次请求走 `@http.request`，新建连接 | 改用 `@http.Client`（注意 `Client::Client` 要求 URL 的 path 恰好是 `/`，需要自己把地址拆成 host 根 + path），并按 host 缓存客户端 |
| 代理 | 不支持 | `@http.request` 有 `proxy?` 参数，需要在 `Config` 里加 `proxy` 字段并传进来 |
| TLS 校验开关 | 固定为默认（校验） | 需要走 `@http.Client::Client(trust~)`，同样是连接复用的路径 |
| 响应 cookie | 读不到 `Set-Cookie` | 底层把响应 cookie 单独放在 `Response::cookies` 里，没有并进 headers。要暴露需要先决定多值头的表示（本项目的 `Headers` 一个名字只能有一个值） |
| 上传/下载进度 | 不支持 | 需要流式 API（`*_stream` 系列）而不是 `@http.request` 的一次性调用 |

改动这些能力时请只动 `src/transport/`，并保持 `PreparedRequest` / `RawResponse` 的字段语义不变——上层的合并、拼接、校验逻辑依赖这份契约。

## `MockTransport` 的用法

```moonbit
let mock = @transport.MockTransport::new(response)          // 始终返回该响应
let mock = @transport.MockTransport::from_responses(queue)  // 按队列返回，用完后复用最后一个
let mock = @transport.MockTransport::failing(error)         // 总是失败
let transport : &@transport.Transport = mock

// 请求发生后断言发出去的内容
let sent = mock.last_request().unwrap()
println(sent.url)
println(sent.headers.to_string())
```

队列空了之后复用最后一个响应，是为了让「同一个响应要被请求多次」的用例不必重复塞响应；完全没有配置响应时抛 `TransportError::Unsupported` 而不是返回空响应——静默的成功会让测试变得不可信。

`MockTransport` 是公开 API（不只是测试内部工具），使用方可以用它给自己的代码写不联网的测试。
