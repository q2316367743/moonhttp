# httpconn —— 自研 HTTP/1.1 传输实现

`Transport` trait 的真实实现：自己拨号（TCP / TLS / CONNECT 隧道）、自己写请求、自己读响应。
2026-09-30 起是 `Client::new` 的**缺省传输**——不传 `transport~` 就是它
（旧栈 `moonbitlang/async/http` 已删除，设计与行为对照见
[`docs/18-httpconn-transport.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/18-httpconn-transport.md)）。

```toml
import {
  "q2316367743/moonhttp/httpconn",
}
```

## 公开 API

| 项 | 说明 |
|---|---|
| `HttpConnTransport::new()` | 创建传输实现（无状态：phase 1 每请求一条连接） |
| `Transport` 实现 | `send(PreparedRequest) -> RawResponse`：建连 → 写头写体（含上传进度回调）→ 等响应头 → 按分帧交出响应体流 |
| `parse_target(url) -> Target` | 把绝对 URL 切成拨号要的形状（scheme / use_tls / host / port / 请求目标）；非 http(s) 抛 `TransportError::Unsupported` |
| `host_header(target)` | `Host` 头的值（默认端口按 RFC 9112 §7.2 省略） |

`Target` 的字段是 `pub(all)`，但它是实现的内部形状，使用者一般不需要碰。

## 行为要点

- **协议**：HTTP/1.0 / 1.1（h2 等上游 ALPN）；请求体一律 `Content-Length`（无体发 0），
  每请求一条连接、发 `Connection: close`（连接池是第 2 期）。
- **自定义方法**：`PROPFIND` 等按原样落进请求行；token 校验在**建连前**
  （拼不进请求行的方法不值得一次握手）。
- **gzip 自持**：请求没声明 `Accept-Encoding` 时由本实现声明 `gzip` 并在响应侧流式解压，
  解压后摘掉 `Content-Encoding` / `Content-Length`（「谁解压谁声明」，见
  [`docs/15-response-compression.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/15-response-compression.md)）。
- **代理**：http 与 https 目标都走 `CONNECT` 隧道，`Proxy-Authorization` 只落在
  CONNECT 请求上；SOCKS5 在路线图上（连接层已留位），见
  [`docs/09-proxy.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/09-proxy.md)。
- **取消 / 超时**：整跳（建连、TLS / CONNECT 握手、写头写体、等响应头）包在取消作用域里、
  受 `timeout` 约束；响应体阶段由 `ResponseBody` 按单次读取管，见
  [`docs/12-cancellation.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/12-cancellation.md)。

## 用法

```moonbit nocheck
// 缺省即自研栈：不传 transport~ 就是 HttpConnTransport

///|
let client = @moonhttp.Client::new()

///|
// 也可以显式注入（与自定义实现走同一入口）

///|
let transport : &@transport.Transport = @httpconn.HttpConnTransport::new()

///|
let explicit = @moonhttp.Client::new(transport~)
```
