# 10 上传 / 下载进度

对应 axios 的 `onUploadProgress` / `onDownloadProgress`。两个字段都是 `Config` 上的可选回调，走**策略 2**（请求级优先，否则回退实例默认值）。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/config/progress.mbt` | `ProgressEvent` / `ProgressCallback` 与两个 `with_on_*` 构建器 |
| `src/config/config.mbt` | 两个字段本身（合并策略的分组注释也在这里） |
| `src/config/merge.mbt` | `prefer_request` 那一档（请求级整体替换实例默认值） |
| `src/transport/async_http.mbt` | 上传：`write_body` 分块写 + 逐块回调；`content_length` 解析响应头 |
| `src/transport/stream_all.mbt` | 下载：读全量时逐块回调（`drain_into` / `read_all_partial`） |
| `src/transport/stream.mbt` / `stream_lifecycle.mbt` | `ResponseBody::total`（进度的分母从哪来）；构造在后者 |
| `src/util/request.mbt` | 把 `Config::on_upload_progress` 透传进 `PreparedRequest` |
| `src/client.mbt` | `Client::request` 读全量时接上下载回调 |
| `src/facade.mbt` | `StreamResponse::read_all` 同样接上下载回调；再导出两个类型 |
| `src/config/progress_test.mbt` | 配置层用例：`progress()`、构建器、合并、渲染 |
| `src/progress_test.mbt` | 端到端用例：Mock 的确定性多块 + 本机 server 的真实连接 |

## 数据结构

```moonbit
pub(all) struct ProgressEvent {
  loaded : Int      // 已传输字节
  total : Int?      // 总字节；None = 长度未知（对应 axios 的 lengthComputable === false）
}

pub fn ProgressEvent::progress(Self) -> Double?   // 0.0 ~ 1.0；total 未知或为 0 时 None

pub type ProgressCallback = (ProgressEvent) -> Unit noraise
```

与 axios 原生 `ProgressEvent` 的差异：没有 `upload` / `download` 布尔标记（方向由「哪个回调被调用」表达）、没有原生 `event` 对象、没有 `bytes` / `rate` / `estimated`。后三个都能自己算：`bytes` 是相邻两次回调的 `loaded` 之差；`rate` / `estimated` 需要读时钟，属于使用方的时间尺度，不该由传输层假装知道。

`ProgressCallback` 是 `noraise` 的：回调在发送 / 读取的中途被调用，它抛出的错误没有合理归属方（既不是这次请求的传输错误，也不该让请求失败）。**回调是同步执行的**，占用的就是这次请求的时间预算——上传回调落在 `timeout` 覆盖的发送阶段里，下载回调落在读全量的那次时限里。别在回调里做耗时的事。

## 上传进度

**触发点**：`AsyncHttpTransport` 把 `PreparedRequest::body` 写出去的时候，按 `UPLOAD_CHUNK_SIZE`（64 KiB）切块，每块 `write` + `flush` 之后报一次。

```
body（完整字节）
  ├─ 64 KiB → client.write + flush → report(loaded = 64 KiB)
  ├─ 64 KiB → client.write + flush → report(loaded = 128 KiB)
  └─ 余下      → client.write + flush → report(loaded = total)
```

几个必须知道的口径：

- **分块不改变线上格式。** 底层不传 `Content-Length` 时本来就把请求体编码成 `Transfer-Encoding: chunked`（它的发送缓冲只有 1 KiB），也就是说整块 `write` 在底层早就被切成很多个 chunk 了。分块只改 chunk 边界，对服务端透明。
- **`loaded` 是「已写入连接」的字节，不是「对端已收到」。** 每块之后的 `flush()` 保证报告时数据已经交给内核，不再堆在库的缓冲里；但 TCP 缓冲区里还剩多少只有对端知道。进度到 100% 之后仍需等待服务端处理，这是所有 HTTP 客户端的上传进度的共同语义。
- **`total` 恒等于 `body` 的字节数**（`PreparedRequest::body` 的长度），所以上传方向的 `total` 总是 `Some`。多部分表单里 boundary 与各部分头都算在内——报的是真实写出去的字节数。
- **没有 body 时不触发。** `body` 为 `None` 或空字节串时一次回调都不会有（没有字节可报）。
- **重定向每跳独立重置。** 每一跳都是一次新的发送，重发 body 的 307/308 会从头再报一轮；被改写成 GET 的 301/302/303 丢掉了 body（见 `08-redirects.md`），于是那一跳不报。
- **由传输实现负责触发。** 换掉 `Transport` 实现就等于换掉了上报行为：`MockTransport` 不发送任何数据，所以它不调用这个回调（要用 Mock 测上传进度的 UI，得自己在测试传输层里调用它）。下载方向不受此限——报告点在 `ResponseBody` 与根包，与传输实现无关。

## 下载进度

**触发点**：凡「库读全量」都报告，一共两条路。

| 入口 | 报告 | 说明 |
|---|---|---|
| `Client::request` | ✅ | 读全量后交给调用方 |
| `StreamResponse::read_all` | ✅ | 调用方要求读全量 |
| `StreamResponse::read_some` / `read_until` | ❌ | 按块读由调用方自己驱动，进度自己累加 |
| `SseStream::next_event` | ❌ | 事件流不是「下载一个确定的字节数」 |

口径：

- **`loaded` 是这次读全量读到的字节数，从 0 起算。** 先 `read_some` 过一段再 `read_all` 时不会接着累加（那是两次读取）。
- **`total` 来自响应体的总长度**：真实连接上是响应头的 `Content-Length`，内存体（Mock）是手上那份字节的长度。响应体总长度不随已读掉的部分变小，`total` 也不变。
- **回调粒度**：真实连接上是每次 `read_some` 拿到的块（对端到货多少算多少）；内存体按 64 KiB 模拟分块，好让 Mock 的用例能确定地观察到多块递增。
- **读失败时进度停在断点**：已经报出去的字节数就是现场，之后抛 `HttpError`（错误里还带着已读到的部分）。

### 为什么 `total` 可能不准

两种已知情况，`loaded` 可能超过 `total`（`progress()` 不截断，直接给出大于 1.0 的值）：

1. **chunked 响应没有 `Content-Length`** → `total` 是 `None`，`progress()` 也是 `None`。这时能回答的只有「已经收到多少字节」。
2. **压缩响应**：底层默认发 `Accept-Encoding: gzip,identity` 并自动解压，`Content-Length` 是**压缩后**的长度，而 `loaded` 数的是**解压后**的字节。响应体被压缩时 `loaded` 会先于 `total` 到达甚至超过它。axios 在浏览器里同样有这个问题。

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 事件对象 | 原生 `ProgressEvent`（`loaded` / `total` / `progress` / `bytes` / `rate` / `estimated` / `upload` / `download` / `event`） | `loaded` + `total` + `progress()` |
| 上传进度 | node 里按流写入时触发 | 分块写 + 每块 `flush` 后触发；粒度固定 64 KiB |
| 下载进度 | node 里 `res.on('data')` 触发，包括 stream 模式 | 只由「库读全量」触发，按块读的路不介入 |
| 回调签名 | 同步函数，可抛错（抛错会 reject 整个请求） | `noraise`：类型上就禁止抛错 |
| 流式上传 | 支持（`data` 可以是 stream） | **不支持**：body 仍是一次性字节，见下文 |

## 不做的事

- **请求体流式上传（Reader 形态的 body）**：进度回调不依赖它（上面已经说明分块写就够），所以本期只做回调。README 的「暂不支持」里标了下一期。
- **取消 / 中断**：已由 `cancel_token` 承担（`docs/12-cancellation.md`），并且取消会打断挂起中的
  上传写入——从上传进度回调里调 `CancelToken::cancel` 就能停在下一块。
- **节流**：回调次数等于块数（64 KiB 一块）。要按百分比节流，在回调里自己判断。

## 注意事项（改动时）

1. **粒度常量两处**：上传是 `src/transport/async_http.mbt` 的 `UPLOAD_CHUNK_SIZE`，内存体的下载报告粒度是 `src/transport/stream_all.mbt` 的 `PROGRESS_CHUNK_SIZE`。改它们会让 `src/progress_test.mbt` 里「精确断言块数」的用例失败——那是故意的，改粒度就该同步改断言。
2. **回调不能在 `noraise` 之外被调用**：`read_all_partial` 声明是 `noraise`，回调类型也是 `noraise`，两者是配套的。想让回调能抛错，先想清楚错误该归给谁。
3. **`ResponseBody::total` 在构造时定下**，不随读取变化。加新的响应体来源（例如未来的连接池）时要一并给出 total，否则下载进度的分母就没了。
4. **`PreparedRequest` 的手写 `Debug`**：它因为多了一个函数类型字段而不能 `derive(Debug)`，实现里刻意不打印 `body` 的字节内容与 `proxy` 的凭据。加字段时保持这个口径，`src/transport/transport_test.mbt` 有一条快照用例钉着它。
