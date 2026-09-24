# transport —— 传输层契约

本模块**唯一**依赖 `moonbitlang/async` 的包。它把「真正把字节发出去」抽象成一个 `Transport` trait，上层只认 `PreparedRequest` / `RawResponse` 两个契约——换实现不破坏上层 API，也让整条管线能在无网络下测试。

```toml
import {
  "q2316367743/moonhttp/transport",
}
```

## 契约

| 类型 | 内容 |
|---|---|
| `Transport`（trait） | 只有一个方法：`async fn send(Self, PreparedRequest) -> RawResponse raise TransportError` |
| `PreparedRequest` | 方法、完整 URL、拍平后的头、body 字节、超时、代理端点、上传进度回调、取消句柄 |
| `RawResponse` | 状态码、状态短语、响应头、响应体**流** `ResponseBody` |
| `ProxyEndpoint` | `{ url, authorization? }`：隧道地址与 CONNECT 的凭据 |
| `TransportError` | `Timeout` / `Network(String)` / `Unsupported(String)` / `Cancelled`；分类在根包翻译成 `HttpError` |

## `ResponseBody` 的读法

| 方法 | 说明 |
|---|---|
| `from_bytes(bytes)` | 手里已有完整响应体时包一层（Mock 与测试用） |
| `read_all(on_progress?)` | 读到 EOF；传了回调就逐块报下载进度 |
| `read_all_partial(on_progress?)` | 同上但**不抛错**：返回 `(已读到的字节, 失败原因?)`，「读到一半失败」时保住现场 |
| `read_some(max_len?)` | 读一块，`None` 表示 EOF |
| `read_until(delim)` | 读到分隔符（含分隔符）为止 |
| `close()` | 释放连接 |

超时在这里分两种口径：`read_all` / `read_all_partial` 是「整段读完」一个时限，`read_some` / `read_until` 是「每次等待」一个时限。

## 两个实现

- **`AsyncHttpTransport`**：真实实现，基于 `moonbitlang/async`。每次请求新建连接（不做连接复用），代理用 `CONNECT` 隧道、http 与 https 目标都一样；取消作用域也在本包（取消信号能打断挂起中的连接动作）。
- **`MockTransport`**：测试用，不碰网络。记录收到的每一份请求（`received()` / `request_count()` / `last_request()`），返回预置响应（`new(response)` 或 `from_responses([...])`，取完之后一直复用最后一个），也可以固定失败（`failing(error)` / `with_failure(error)`）。

## 用法

```moonbit nocheck
// 在测试里替换掉真实网络

///|
let mock = @transport.MockTransport::new(response)

///|
let transport : &@transport.Transport = mock

///|
let client = @moonhttp.Client::new(transport~)
```

自定义传输只要实现一个方法，底层类型完全被挡在上层之外：

```moonbit nocheck
///|
pub impl Transport for MyTransport with fn send(self, request) {
  // request  : PreparedRequest（方法、完整地址、已拍平的头、body、超时）
  // 返回      : RawResponse（状态码、状态短语、响应头、响应体流）
  ...
}
```

字段含义、超时语义与自定义传输的注意事项见
[`docs/05-transport.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/05-transport.md)。
