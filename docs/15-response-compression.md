# 15 响应体的压缩（gzip）

**一句话**：声明了 `Content-Encoding: gzip` 的响应由库负责解掉——`Client::request`（读全量）由库自己声明压缩并解压；
流式路径由 httpconn 自己声明 gzip、自己流式解压（谁解压谁声明）。`with_decompress(false)` 可整体关掉。

> **状态更新（2026-09-30，旧栈删除）**：两条路径的解压都归本库自持——缓冲路径
> `decode_gzip`（本文下述）、流式路径 httpconn 用 `@gzip.Decoder` 包住分帧 reader。
> 旧栈「底层补了 `Accept-Encoding` 才透明解压」的私有判据随旧栈删除；
> 判定锚点始终是自己请求头里有没有 `Accept-Encoding`。规则表见
> `18-httpconn-transport.md` 的 gzip 一节（自研栈的摘头在 `httpconn/transport.mbt`
> 的 `build_raw_response`）。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/transport/decode.mbt` | `decode_gzip`（把一整份 gzip 字节解成实体字节，缓冲路径用）、`declares_gzip`（「这份响应声称自己是 gzip」的唯一判据） |
| `src/httpconn/transport.mbt` | `build_raw_response`：流式路径的声明检测、`@gzip.Decoder` 包分帧 reader、解压后摘 `Content-Encoding` 与 `Content-Length` |
| `src/client.mbt` | `declared_encoding`（这次请求声明什么）、`decode_response_body`（缓冲路径解压 + 摘头 + 失败分类） |
| `src/util/request.mbt` | `build_prepared_request` 的 `accept_encoding` 参数：声明按 `set_if_absent` 落地（用户显式设置永远优先） |
| `src/config/decompress.mbt` | `Config::with_decompress`；字段定义在 `config.mbt`，默认值 `Some(true)` 在 `default.mbt`，合并走策略 2（`merge.mbt`） |
| `src/transport/decode_wbtest.mbt` | 解压、失败分类与摘头判据的单元用例 |
| `src/gzip_test.mbt` | 端到端用例：Mock（库自己解压这条路）+ 本机 server（真实连接上的两条路径） |

## 规则表

| 入口 | 谁声明 `Accept-Encoding` | 谁解压 | 交出去的头 | 失败怎么报 |
|---|---|---|---|---|
| `request`（读全量） | **库**发 `gzip, identity` | **库**（读全量后内存解压） | 解压成功：摘掉 `Content-Encoding` + `Content-Length`；解压失败：两者原样保留 | `ERR_BAD_RESPONSE`（`TransportError::Malformed`），错误里的响应保留原始压缩字节与头 |
| `stream` / `sse` | **库**（httpconn）发 `gzip` | **库**（httpconn 挂 `@gzip.Decoder`，边到边） | 解压成功：摘掉 `Content-Encoding` + `Content-Length`（`total` 随之归 `None`） | 中途解不开：读失败报 `TransportError::Network`（解码器错误原文），流已关闭 |
| `decompress: false`（两条路径） | **库**发 `identity`（挡住服务端压缩，也挡住自动解压） | 无人 | 全部原样 | — |
| 用户自己设了 `Accept-Encoding` | 库一律不覆盖（`set_if_absent`） | 缓冲路径仍由库解 gzip；流式无人解 | 与字节一致 | 同上 |

两条贯穿性口径：

- **「响应头里还有 `Content-Encoding`」⟺「交出去的字节仍是编码后的」**。头描述的是交出去的字节，不是线上字节：
  解掉的编码一定从头上摘掉，没解的（别的编码、关掉开关、解压失败）一定留着。`Content-Length` 同理——它描述线上长度，
  解压后留一个对不上的数字比不留更坏。
- **不认识的编码一个字节都不动**：`br` / `deflate` / 多值列表（`gzip, br`）既不解压也不报错，字节与头原样交出去。
  假装认识会得到「把没解压的字节当实体字节」这种更难查的错。空体（HEAD 这类带 `Content-Encoding` 却没有字节的响应）同样不解压，
  响应头也原样留着——硬解一份零字节的流只会换来一个假失败。

## 为什么是「两条路径、两套机制」

底层的 `@http.Client` 有一个自动行为：**它自己补 `Accept-Encoding: gzip,identity` 时，会顺带在响应头声明 gzip 的情况下
挂一个 `@gzip.Decoder` 透明解压**（并删掉 `Content-Length`）。也就是说「真网络上的 gzip 能解」在本项目里一直成立，
但那是底层的顺手行为，带着三个裂缝：

1. 解压后响应头里仍留着 `Content-Encoding: gzip`（头与体互相矛盾）；
2. 用户一旦自己设了 `Accept-Encoding`，底层就不解压了，压缩字节会被当正文交给 `text()`；
3. Mock / 自定义传输层完全不解压，这条能力没法用现有测试基建覆盖。

于是缓冲路径改为**由库声明、由库解压**：缓冲路径发 `gzip, identity`，响应声称 gzip 就在读全量后由 `decode_gzip` 内存解压。
流式路径在当时的选择是**搭底层透明解压的便车**（不声明 → 底层补上并解压），库只负责把 `Content-Encoding`
这句已经不成立的话摘掉——旧栈 `async_http.mbt` 的 `without_decoded_encoding` 干的就是这件事。

> **本节其余是旧栈时期的设计动机，留作历史。** 2026-09-30 旧栈删除后，流式路径改为 httpconn
> 自己声明 `gzip`、自己用 `@gzip.Decoder` 包住分帧 reader 边到边解压（「谁解压谁声明」），
> 摘头在 `src/httpconn/transport.mbt` 的 `build_raw_response`；现行规则表见
> `18-httpconn-transport.md` 的 gzip 一节。

`decompress: false` 时两条路径都声明 `identity`：既让服务端别压缩，也让自动解压不介入
（流式路径因此也能关掉解压，见 `src/gzip_test.mbt` 的「streaming with decompress false」用例）。

## 为什么不在 `ResponseBody` 上做懒解压

`@gzip.Decoder` 只接受 `@io.Reader`。缓冲路径不需要它——读全量之后解压是纯内存变换（`decode_gzip` 借一个内存管道
把字节喂给解码器，与 async 库自测里同一件事的写法一致）；流式懒解压才需要 Reader 适配。

> **勘误（2026-09-29）**：本文初版写「实现 `@io.Reader` 需要命名 async 包内部的 `ReaderBuffer`，跨模块做不到」
> ——实测不成立：`ReaderBuffer::new()` 是公开 API，trait 的两个必需方法也未标内部。
> 自研传输层正是靠包外实现 `@io.Reader` 做的分帧流（含 `@gzip.Decoder` 的包装），见 `18-httpconn-transport.md`
> 的「有意的赌注与它的哨兵」——这条路唯一的代价是上游把 `ReaderBuffer` 标了内部用途，按包关掉一条告警。

## 失败分类与现场

gzip 数据损坏、被截断（CRC32 或长度校验不过、`NeedMoreInput`）、只有头没有数据，都收敛成
`TransportError::Malformed(message)`，对外报 `ERR_BAD_RESPONSE`——这不是网络故障，是响应本身解不开
（`04-errors.md` 的错误码表）。错误里挂着**原始压缩字节与原始响应头**：解不开的就是这份字节，
头照原样留着才看得出它声称自己是 gzip。

**状态码也没通过校验时以状态码为准**：404 的错误页解不开，说「404」比说「解压失败」有用；
这时响应体与响应头都原样交出去（`decode_response_body` 返回 `Err` 而不是直接抛，
由 `Client::dispatch_request` 结合校验结果决定报哪个）。

## 进度口径

解压发生在**读全量之后**，所以下载进度（`on_download_progress`）数的是**线上字节**：
`loaded` 是收到的压缩字节数，`total` 是 `Content-Length`（压缩后长度），两者永远同一个口径，
不存在「解压后比 total 还大」。`Response::bytes()` / `content_length()` 说的是**解压后**的实体字节——
读法与进度各说各的字节，这正是它们的定义（见 `10-progress.md`）。

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 开关 | Node 适配器有 `decompress: true`（浏览器由 XHR / fetch 代管，看不到这两个头） | 同名同义（`with_decompress(false)`），两条入口都生效 |
| 解压位置 | Node 适配器在收到响应流时挂 zlib | 缓冲路径读全量后由库解；流式由 httpconn 挂流式解码器（见上） |
| 支持的编码 | gzip / deflate / br（Node 有 zlib） | **只有 gzip**：`moonbitlang/async` 只提供 gzip 的编解码器 |
| 响应头 | 两个头在 Node 下仍可见 | 解压后摘掉 `Content-Encoding` 与 `Content-Length`（与浏览器一致：这两个头本来是隐藏的） |

## 不做的事

- **流式解压的对外语义**：httpconn 自持（见状态更新）；`decompress: false` 让它明确地不解压
  （声明换成 `identity`，字节与头都保持线上原样）。
- **`deflate` / `br` / `zstd`**：`moonbitlang/async` 只提供 gzip；别的编码要有实现才谈得上支持。
- **请求体压缩上传**：本期只做响应侧。
- **自动改写用户显式设置的头**：`Accept-Encoding` 用户设过就一字不动（`set_if_absent`），
  那时缓冲路径仍会解 gzip（「交出去的体一定解压」是这条路径的承诺），流式路径则交压缩字节、头留着
  （两条路径一致）。
