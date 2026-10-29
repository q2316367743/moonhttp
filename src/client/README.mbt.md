# client —— 编排层

`Client` 实例、三个请求入口、七个动词快捷方法、两段拦截器、自动重定向、流式响应与所有「构造 `HttpError`」的动作都在这里。它是唯一会抛 `HttpError` 的包：`response`（响应值）与 `http_error`（错误契约）在它的下游，纯值不抛错、纯契约不造错。

```toml
import {
  "q2316367743/moonhttp/client",
}
```

通常不必直接 import 本包：根包 `@moonhttp` 已把 `Client` / `Interceptors` / `StreamResponse` / `SseStream` 与工厂函数 `create` / `default_client` 再导出。

## `Client`

| 入口 | 说明 |
|---|---|
| `request(config, signal?)` | 发送请求并读全响应体；两段拦截器都跑，失败按来源分流到两条错误链 |
| `stream(config, signal?)` | 不读响应体，交还原始字节流（下载）；只过请求拦截器 |
| `sse(config, signal?)` | 按事件读的 SSE 流，要求响应头声明 `text/event-stream`；只过请求拦截器；自动重连按 `config.sse_reconnect` 开启 |
| `get` / `post` / `put` / `delete` / `patch` / `head` / `options` | 七个动词快捷方法：补 `url` 与动词后转调 `request` |
| `create(config)` | 派生新实例：叠加默认值，继承拦截器与 cookie 罐 |
| `new(config?, transport?, interceptors?, cookie_jar?)` | 完整构造：可注入传输层 / 拦截器 / cookie 罐 |

## `StreamResponse` / `SseStream`

`StreamResponse` 是原始字节流：`read_some()`（按块）、`read_until(sep)`（读到分隔符）、`read_all()`（读到 EOF，失败时已读字节挂在错误响应上）、`close()`。`SseStream` 是事件流：`next_event()` 返回解析好的 `@sse.SseEvent?`。两者读失败都抛 `HttpError`，错误里带着已收到的状态行与响应头。**中途停止必须 `close()`**，否则漏连接。

`SseStream` 的自动重连默认关闭；用 `Config::with_sse_reconnect(...)` 开启后，`next_event()` 会在 EOF / 可重试错误上按流里的 `retry` 重订阅并自动带 `Last-Event-ID`。触发条件、次数上限与取消语义见 [`docs/06-sse.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/06-sse.md)。

## 拦截器

```moonbit nocheck
///|
let api = @moonhttp.Client::new(
  interceptors=@moonhttp.Interceptors::new()
    .use_request(config => config.with_header("X-Token", token))
    .use_response(resp => resp.with_status(200)),
)
```

请求侧后注册先跑（LIFO）、响应侧先注册先跑（FIFO），对齐 axios；与 axios 的有意差异是错误按来源分流——请求阶段的失败只走请求侧错误处理器，响应侧错误处理器只接状态码校验失败。链是值语义：`use_*` / `remove_*`（按名撤下）都返回新集合。

管线、重定向与错误分流的完整规则见
[`docs/03-request-pipeline.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/03-request-pipeline.md) 与
[`docs/11-interceptors.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/11-interceptors.md)。
