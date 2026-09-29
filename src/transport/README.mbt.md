# transport —— 传输层契约

传输层：把「真正把字节发出去」抽象成 `Transport` trait，上层只认 `PreparedRequest` / `RawResponse` 两个契约。自带基于 `moonbitlang/async` 的 `AsyncHttpTransport`，也可以在测试里换成 `MockTransport` 或自己的实现。

```toml
import {
  "q2316367743/moonhttp/transport",
}
```

## 契约

| 类型 | 内容 |
|---|---|
| `Transport`（trait） | 只有一个方法：`async fn send(Self, PreparedRequest) -> RawResponse raise TransportError` |
| `PreparedRequest` | 方法、完整 URL、拍平后的头、body 字节、超时、代理端点、上传进度回调、取消信号 |
| `RawResponse` | 状态码、状态短语、响应头、响应体**流** `ResponseBody` |
| `ProxyEndpoint` | `{ url, authorization? }`：隧道地址与 CONNECT 的凭据 |
| `TransportError` | `Timeout` / `Network(String)` / `Unsupported(String)` / `Malformed(String)` / `Cancelled(String?)`；上层看到的 `HttpError` 分类就来自它（`Malformed` 是「响应体与它声称的 `Content-Encoding` 不符」，报 `ERR_BAD_RESPONSE`），取消的载荷是取消理由 |

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

## 解压与响应头

`Content-Encoding` 的解码工具也在这个包（只有它碰 async 运行时）：`decode_gzip(bytes)` 把一整份 gzip 字节解成实体字节，`declares_gzip(headers)` 判断响应是否声称自己是 gzip。**流里没有「内容编码」这一层**——交出去的 `ResponseBody` 永远是实体字节；自定义传输实现若要交 gzip 字节，就得把 `Content-Encoding` 一起交出去（让头与体说同一件事）。谁声明、谁解压、失败怎么报见
[`docs/15-response-compression.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/15-response-compression.md)。

## 两个实现

- **`AsyncHttpTransport`**：真实实现，基于 `moonbitlang/async`；代理用 `CONNECT` 隧道，http 与 https 目标都一样；每次请求新建连接（不做连接复用）。
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
