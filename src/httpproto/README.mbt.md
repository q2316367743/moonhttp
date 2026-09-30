# httpproto —— HTTP/1.x 协议层（纯逻辑）

自研 HTTP/1.x 的**协议层**：状态行解析、头块解析、响应体分帧判定、chunked 增量解码、
请求头块渲染。全部是纯逻辑——不依赖 async 运行时、不碰网络，因此能用普通同步测试覆盖；
实现层（[`httpconn`](https://github.com/q2316367743/moonhttp/blob/master/src/httpconn/README.mbt.md)）
负责把网络字节喂进来。协议错误只表达「坏在哪一类」（`ParseError::Malformed` /
`Unsupported`），翻译成 `TransportError` 归 httpconn（见
[`docs/18-httpconn-transport.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/18-httpconn-transport.md)）。

```toml
import {
  "q2316367743/moonhttp/httpproto",
}
```

## 公开 API

| 项 | 说明 |
|---|---|
| `parse_status_line(line)` | 解析状态行（版本 / 状态码 / 短语）；不是状态行或 HTTP/2 前言这类「能力边界」抛 `ParseError` |
| `parse_header_block(lines)` | 头块 → `HeaderMap`：多值收全、obs-fold 折行展开、裸 CR/LF 等非法头行拒绝 |
| `body_framing(is_head, status, headers)` | 分帧判定 → `Empty` / `Chunked` / `Length(n)` / `UntilClose`（无体规则；多条不一致的 `Content-Length` 按走私形状拒绝） |
| `render_request_head(method, target, headers)` | 把请求行与头块渲染成线上字节；方法 / 头名不是合法 token 抛 `ParseError` |
| `is_token(s)` | RFC 9110 token 字符判定（方法与头名共用的准入校验） |
| `HeaderMap` | 保序 multimap：`append` / `set` / `set_if_absent` / `get_first` / `get_last` / `get_all` / `remove` / `has` |
| `ChunkDecoder` | chunked 增量解码器：`feed(bytes)` 吐数据段，`finish()` 校验收尾，`is_done()` 查状态 |

## 用法

```moonbit nocheck
///|
let status = @httpproto.parse_status_line("HTTP/1.1 200 OK")
// status.code == 200

///|
// 分帧判定：有 Content-Length 就是定长

///|
let headers = @httpproto.HeaderMap::new()
headers.set("Content-Length", "11")

///|
let framing = @httpproto.body_framing(false, 200, headers)
// framing is Length(11)
```

「怎么从连接上按帧切字节」的 I/O 驱动在 `httpconn`，本包不做任何网络操作。
