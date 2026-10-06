# 20. 流式上传（读取流作为请求体）

> 2026-10-05 落地。第五种请求体形态：调用方给一个**读取流**，传输层边读边写，
> 请求体不再需要整块驻留内存。README 的「暂不支持」条目已随之移除。

## 四个定案（实现前与 owner 确认）

| 问题 | 定案 | 理由 |
|---|---|---|
| 流的形态收哪种 | **只收读取流**（`&@io.Reader`，pull） | 库控制节奏 / 分块 / 进度 / 取消；「边生成边推」的 push 场景走官方 `MemoryReader` 桥（它的构造器本来就是「回调里拿 `&Writer` 往里写」），不引入第二个 API。与 Go `io.Reader` / Rust `Read` / Node Readable 同构，pipe、`@gzip.Decoder` 等现成 Reader 都能直接接 |
| 放在哪一层 | **Config 第五形态**（`Body::Stream` + `with_data_from_stream`） | 与四个 `with_data_from_*` 家族统一、天然互斥；shortcuts / 拦截器 / merge 自动兼容。代价：config 包 import 了 `moonbitlang/async/io`——只是类型引用（把用户造好的流原样转交），本包不执行任何 IO，同步测试口径不变 |
| 线上分帧 | **双模式**：`content_length?` 给了走 `Content-Length` 定长，没给走 `Transfer-Encoding: chunked` | 定长兼容老网关与 HTTP/1.0 目标、进度 `total` 已知；chunked 服务「不知道总长度、边生成边发」的核心场景。写出字节数与声明不符在发送侧直接报错 |
| 遇到重定向 | **307/308 报错**（`ERR_NOT_SUPPORT`），其余照常降 GET | 流在首跳写完就耗尽。303 与 301/302 上的 POST 在 `next_redirect` 里已降 GET 丢 body，不需要重放；307/308（及 301/302 上保持方法的跳转）语义是原样重发——重放已耗尽的流只会静默发空体，明确报错。fetch 对 stream body + redirect 也是直接失败 |

## 链路（自上而下）

```
Config::with_data_from_stream(reader, content_length?)
  └─ Config.data = Body::Stream(StreamBody { reader, content_length })   config/body.mbt
       └─ Config::extract_body() 分流：Buffered(SerializedBody) | Stream(StreamBody)
            └─ util/build_prepared_request：Stream 原样装进（不读、不补 Content-Type）
                 └─ PreparedRequest.body : RequestBody? = Stream(StreamBody)   transport
                      └─ httpconn/build_request_headers：分帧头接管（见下）
                           └─ httpconn/write_stream_body：泵循环（64 KiB 拉取 → 写连接）
                                └─ httpproto/render_chunk_frame / render_last_chunk（chunked 模式）
```

- `serialize_body()` 对流式形态返回空（它只回答「字节是什么」）；分派两种形态统一走
  `extract_body()`，返回 `BodyPayload`（`Buffered(SerializedBody) | Stream(StreamBody)`）。
- `Config::has_stream_body()` 供根包重定向循环判断（`client.mbt`）。

## 数据结构 / API 契约

```moonbit
// config 包
pub(all) struct StreamBody {
  reader : &@io.Reader        // 拉取侧；read_some 返回 None（EOF）即请求体收尾
  content_length : Int?       // Some → 定长；None → chunked；也是上传进度的 total
}
pub fn Config::with_data_from_stream(self, reader : &@io.Reader, content_length? : Int) -> Config

// transport 包（公开破坏性变更：原 body : Bytes? 改为 RequestBody?）
pub(all) enum RequestBody {
  Buffered(Bytes)   // 四种缓冲形态序列化完的字节
  Stream(StreamBody)
}
```

### 语义细则

| 主题 | 口径 |
|---|---|
| 互斥 | 与其余四个 `with_data_from_*` 一样整体替换 `data`，后调覆盖先调 |
| Content-Type | **不推断**（与 `with_data_from_str` 一致），要带类型头自己 `with_header` |
| 分帧头接管 | 流式形态下 `Content-Length` / `Transfer-Encoding` 由 httpconn 全权管理：用户预设的一律摘掉（预设长度可能与实际写出不符、两头并存是协议矛盾），再按模式落。**缓冲形态不受影响**，仍是 `set_if_absent`（用户显式设置仍然赢） |
| 进度 | 与缓冲路径同口径：每写完一个 64 KiB 块回调一次（`UPLOAD_CHUNK_SIZE`）；定长模式 `total = Some(n)`，chunked 模式 `None`（与下载侧 chunked 响应一致） |
| 超时 | 沿用整跳口径：建连 → TLS → 写头 → **写完整个请求体** → 响应头，一个 `timeout` 时限。慢速大上传要么调大要么设 `None` |
| 取消 | 泵循环活在 `with_abort_scope` 内（整跳），取消落在块与块之间 / 挂起的读写上都会立刻断，报 `ERR_CANCELED` |
| 空块 | `read_some` 返回空 `Some` 跳过——chunked 下零长度帧等于终止帧（提前截断报文）；EOF 只认 `None` |
| 拦截器 | 请求拦截器拿到 `Config`：读不到也耗不坏流（`data` 私有）；`with_data_from_*` 照常整体替换 |
| merge | `data` 只取请求级：实例 defaults 里的流会被丢弃。**别把流放进 defaults**——流是一次性资源，被静默复制使用比丢弃更危险 |
| Mock | `MockTransport` 记录 `RequestBody::Stream` 的引用、**不消费**（与「不真发送、不报上传进度」同一契约）；验证线上行为用 httpconn 真测或 `test/server.py` 的 `/upload` |

### 错误映射

| 情形 | 结果 |
|---|---|
| 读源失败（如 `MemoryReader` 回调抛错） | `TransportError::Network` → `ERR_NETWORK`（与写失败同映射） |
| 定长模式写出字节数 ≠ 声明 | `TransportError::Malformed` → `ERR_BAD_RESPONSE`（本地数据与声明对不上；`Malformed` 的口径已扩为「实体与它声称的元数据不符」，两侧各一处来源） |
| 307/308 / 保持方法的 3xx | `HttpError`（`ErrorCode::NotSupported` → `ERR_NOT_SUPPORT`），错误上挂那个 3xx 响应（`stream_replay_error`，与 `too_many_redirects_error` 同做法） |
| 渲染空帧（理论不可达，泵已跳过空块） | `ParseError::Malformed` → `Malformed`（`render_chunk_frame` 的最后防线） |

## 配方

**生成式数据源（push 场景）**——官方 `MemoryReader` 桥，回调正常结束即请求体收尾、抛错即上传失败：

```moonbit nocheck
let reader : &@io.Reader = @io.MemoryReader() <| writer => {
  for i = 0; i < segments; i = i + 1 {
    writer.write(make_segment(i))
  }
}
Config::new("/upload").with_method(Method::Put).with_data_from_stream(reader)
```

**生产者协程**——`@io.pipe()` 的读端直接当请求体，写端在另一个协程里喂数据。

**请求体 gzip 自己包**：`@gzip` 只有「压缩 Writer」，没有「压缩 Reader」——要发 gzip 过的流式请求体，
用 `MemoryReader` 把 `@gzip.Encoder` 桥成读侧（库给响应体解压、不给请求体压缩，`Accept-Encoding`
声明的是响应侧的压缩，两头别混）。

## 边界

- **流是一次性资源**：同一个流不要发两次请求；重放语义见上表（307/308 报错）。
- **HTTP/1.0 目标**：1.0 不认 chunked 请求体——给这类目标上传必须传 `content_length`（定长模式）。
- 缓冲四形态的线上行为不变（仍是一律 `Content-Length`）；只有流式形态走新分帧。
- `Transfer-Encoding: chunked` 的请求侧渲染落在 `httpproto/chunk_render.mbt`，与
  `chunked.mbt` 的解码状态机互为对偶（往返测试互相钉死）。

## 关键文件

| 文件 | 内容 |
|---|---|
| `src/config/body.mbt` | `StreamBody` / `Body::Stream` / `with_data_from_stream` / `extract_body` / `has_stream_body` |
| `src/transport/transport.mbt` | `RequestBody` 枚举；`PreparedRequest.body` 改型；Debug 渲染（流只给长度） |
| `src/util/request.mbt` | `extract_body` 分派：字节落 `Buffered`，流原样透传 |
| `src/httpproto/chunk_render.mbt` | `render_chunk_frame` / `render_last_chunk`（发送侧） |
| `src/httpconn/request_write.mbt` | 分帧头接管 + `write_stream_body` 泵循环 + 长度校验 |
| `src/client.mbt` + `src/http_error.mbt` | 重定向循环的流检查 + `stream_replay_error` |
| `test/server.py` | `/upload` 路由：读干净 CL / chunked 两种请求分帧，回执实收字节数（Python 手写 chunked 请求解码） |
| `src/main/transport` | 第 11 段 `upload_stream`：3 MiB 两种分帧各打一次 + 进度两态 |

## 验证

- 单测：`httpproto/chunk_render_test.mbt`（形状 + 与解码状态机的往返）、
  `config/body_stream_test.mbt`（互斥 / 分流 / 渲染 / merge / 重定向态度）、
  `transport/transport_test.mbt`（流式 Debug）、
  `httpconn/request_stream_real_test.mbt`（裸 TCP 真测：两种分帧的线上字节、
  长度不符 Malformed、读源失败 Network）；
- 根包：`request_test.mbt`（流经管线原样落 `RequestBody::Stream`）、
  `redirect_test.mbt`（307 报错带响应、303 照常降 GET）；
- e2e：`bash test/run.sh` 第 11 段——Python 靶子两种分帧各实收 3145728 字节。
