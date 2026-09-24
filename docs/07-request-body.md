# 07 请求体

`Config` 的请求体是**私有字段**，只能经四个构建器设置；字节由 `Config::serialize_body()` 产出。
本篇记录这条链路、四种形态的线上格式，以及为什么这么设计。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/config/body.mbt` | 私有枚举 `Body`（四种形态）、`SerializedBody`、四个 `with_data_from_*` 构建器、`serialize_body` |
| `src/config/form.mbt` | `FormData` / `FormValue` / `FormFile` 与 `multipart/form-data` 编码（含 boundary、转义） |
| `src/config/render.mbt` | `Config::to_string` 里 `data` 一栏按形态渲染 |
| `src/util/request.mbt` | `build_prepared_request`：取序列化结果，按建议补 `Content-Type` |
| `src/url/build_url.mbt` | `serialize_params`：urlencoded 请求体与 URL query 共用的序列化器（query 那一侧可被 `params_serializer` 替换，请求体这一侧不可） |
| `src/config/body_test.mbt` | 字节级用例（四种形态 + multipart 布局） |
| `src/request_test.mbt` | 端到端用例（真正写到连接上的头与 body） |

## 为什么 `data` 是私有字段

老实现里 `data : Json?` 是公开字段，`with_data(Json)` 一个入口承担了所有情况，
靠「`Json::String` 原样发送、其它值 `stringify`」这条隐含规则区分。它有三个问题：

1. **`Json::String` 的语义歧义**：`with_data("hi")` 到底该发裸 `hi` 还是 JSON 字面量 `"hi"`？
   同一个 `Json` 值没法同时表达两种意图，且前者不补头、后者要补头。
2. **装不下表单**：含文件的表单是二进制结构，`Json` 里没有它的位置。
3. **同一个 `Json` 值可能是两种线上格式**：`{"a": "1"}` 既可以发成 JSON 文本，也可以发成
   `a=1`，区别只在 `Content-Type`——把它绑在构建器上，才不会出现「body 是表单、头写 JSON」。

所以请求体改成「数据 + 形态标签」的私有枚举 `Body`，四个构建器各管一种形态，
**「设置 body」与「该补什么 Content-Type」绑在一起**，不可能配错。

私有字段有两个连带后果，都是有意的：

- **包外不能写 `Config` 的记录字面量 / 记录展开**——编译器直接拒绝
  （`Cannot use struct update syntax on struct Config because it has private fields`）。
  构造配置只有 `Config::new(url)` / `Config::default()` + `with_*` 构建器一条路。
  包内仍然可以（`config/merge.mbt` 的 `merge_config` 就是逐字段构造的；
  `config/config_wbtest.mbt` 钉住这条），这也是合并契约必须与 `Config` 同包的原因（见 `02-config-merge.md`）。
- **`serialize_body()` 是对外唯一的读法**，返回 `SerializedBody { bytes : Bytes?, content_type : String? }`。
  `bytes = None` 表示不带 body，`content_type = None` 表示不推断类型。

## 四种形态

| 构建器 | 发出去的字节 | 建议补的 `Content-Type` |
|---|---|---|
| `with_data_from_str(String)` | 字符串的 UTF-8 编码，一个字节不改 | **不推断** |
| `with_data_from_json(Json)` | `stringify()` 后的 JSON 文本 | `application/json` |
| `with_data_from_form(FormData)` | `multipart/form-data` 正文（见下） | `multipart/form-data; boundary=<随机>` |
| `with_data_from_urlencoded(Json)` | `a=1&b=2` 形式（见下） | `application/x-www-form-urlencoded` |

`with_data_from_str` 不推断类型是刻意的：它既要能发纯文本，也要能发**调用方自己序列化好的载体**
（例如后端要 `tags=a&tags=b` 这种内置不支持的键值约定，或者 protobuf 之类的二进制）。

最容易被绕进去的是字符串：

```moonbit
// 发出去是 4 个字节: h i !\n 之类，内容就是 hi
Config::new("/x").with_data_from_str("hi")

// 发出去是 "hi"（带引号，4 个字节），Content-Type: application/json
Config::new("/x").with_data_from_json("hi")
```

也就是说，**「是不是 JSON」由构建器决定，不由值的类型决定**。

## 表单：`multipart/form-data`

一律编码成 multipart（纯文本字段也走这条），与浏览器的 `FormData` 行为一致——
这样「有没有文件」不会让线上格式在两种形态之间切换，服务端也只需要实现一套解析。

### 布局

每一项（RFC 7578）：

```text
--B\r\n
Content-Disposition: form-data; name="title"\r\n
\r\n
假期\r\n
--B\r\n
Content-Disposition: form-data; name="avatar"; filename="a.png"\r\n
Content-Type: image/png\r\n
\r\n
<文件字节>\r\n
--B--\r\n
```

- `\r\n` 是唯一的分隔换行，正文里不出现裸 `\n`；
- **文本项不带 per-part `Content-Type`**（浏览器的 `FormData` 与 node 的 `form-data` 都这样；
  多补一条只会让某些服务端把它当成文件）；
- 文件项缺省 `Content-Type: application/octet-stream`，可用 `append_file(..., content_type="image/png")` 指定；
- **结尾的分隔符总是发**：空表单发 `--B--\r\n`（那仍然是一份合法的空表单）；
- boundary 形如 `----moonhttp-<两个随机十进制数>`，**每次 `serialize_body()` 现生成**：
  同一个 `Config` 发两次请求不会复用同一个分隔符，也就不会因为正文里恰好含旧分隔符而串段。

### `name` / `filename` 的转义

按 WHATWG 的表单编码规则：`"` → `%22`、CR → `%0D`、LF → `%0A`，其余字符（含非 ASCII）原样按 UTF-8 写。

这是**刻意与 axios 的差异**：它依赖的 node `form-data` 对这两个值不做任何转义，
字段名里带引号时服务端会把参数解析错位（`name="a"b"`），甚至能被注入额外的头。

### 文件怎么给

```moonbit
let form = FormData::new()
  .append_text("title", "假期照片")
  .append_file("avatar", "a.png", bytes, content_type="image/png")
```

- 只收 `Bytes` + 文件名：**库不读盘**，`config` 包保持纯逻辑（不碰 IO、不碰 async，同步测试可覆盖）。
  读文件、从内存造字节、从别处下载的字节，都由调用方决定。
- 文件名只是 `Content-Disposition` 里的一个字符串，不要带路径（浏览器也不会带）。
- 同名可以出现多次（`append_text` 两次就是两项），顺序即追加顺序，库不做「同名字段覆盖」。
- `FormData` 是值语义：`append_*` 返回新实例，拿一份当模板派生多份不会被改坏。

### 代价：整块驻留内存

`PreparedRequest.body` 是一次性字节，所以表单（含文件）会被完整拼进内存再发。
上传进度回调与流式上传**不支持**（见 README 的「暂不支持」），大文件请自行评估内存。

## URL 编码表单（`application/x-www-form-urlencoded`）

```moonbit
Config::new("/login")
  .with_method(Method::Post)
  .with_data_from_urlencoded({ "user": "alice", "password": "s3cret" })
// 正文: user=alice&password=s3cret
// 头:   Content-Type: application/x-www-form-urlencoded
```

**用的是 URL query 那一个序列化器**（`url/build_url.mbt` 的 `serialize_params`，即 axios 的
`toFormData` / `paramsSerializer` 默认选项）：不重复实现第二套百分号编码，也就不会出现
「query 与 body 编码规则不一致」这种最难查的差异。于是同一份 `Json` 放 query 还是放 body
只差一个方法名：

```moonbit
Config::new("/x").with_params({ "a": 1 })              // /x?a=1
Config::new("/x").with_data_from_urlencoded({ "a": 1 }) // 正文 a=1
```

**请求体这一侧不会被 `with_params_serializer` 改掉**：那个自定义序列化器只管 URL 的
query（见 `03-request-pipeline.md` 的「自定义序列化器」）。axios 里也是分开的——`buildURL`
用 `paramsSerializer`，请求体走的是另一个内部选项 `formSerializer`。

继承来的规则（细节与用例见 `03-request-pipeline.md` 的 query 序列化表与 `url/url_test.mbt`）：

| 输入 | 正文片段 |
|---|---|
| `{"a": "b"}` | `a=b` |
| `{"tags": ["a", "b"]}` | `tags%5B%5D=a&tags%5B%5D=b` |
| `{"filter": {"status": 1}}` | `filter%5Bstatus%5D=1` |
| `{"q": "中文 空格"}` | `q=%E4%B8%AD%E6%96%87+%E7%A9%BA%E6%A0%BC`（空格是 `+`） |
| `{"a": null}` | 整个键被跳过 |

三个要知道的边界：

- **顶层必须是对象**：传数组或标量等于一份空正文（与 axios 的 `paramsSerializer` 一致，
  不会报错——它本来就只有「键值对集合」这一种合法输出）；
- **列表/嵌套走括号约定**：`tags[]=a` 这类是 Rails / PHP / Express 的惯例，方括号会被
  百分号编码。后端要 `tags=a&tags=b` 这种**重复平键**、或者要逗号连接时，
  内置规则不适用，用 `with_data_from_str` 自己拼 + 自己设 `Content-Type`
  （也就是老办法，这条路不会消失）。query 那一侧有 `with_params_serializer` 可以换约定，
  请求体这一侧没有对应的口子；
- **文件不行**：urlencoded 里没有承载二进制的位置，带文件请用 `with_data_from_form`。

## `Content-Type` 是「补」不是「设」

`serialize_body()` 给的是**建议**类型，落到请求上走 `Headers::set_if_absent`：
用户显式设置的 `Content-Type` 永远优先（与 axios `setContentType(..., false)` 一致）。

代价要清楚：如果你手动钉了一个 `Content-Type`，正文仍然按自己生成的 boundary 编码，
**头与正文可能对不上**——库不做「帮你改头」这种事。要自己接管就两头都自己来：

```moonbit
Config::new("/upload")
  .with_data_from_form(form)
  .with_header("Content-Type", "multipart/form-data; boundary=mine") // 头是你的，boundary 仍是库的
```

想彻底自己控制（例如 protobuf，或后端要的键值约定与内置不同），用 `with_data_from_str` 发字节 + 自己设头。

## 与 axios 的差异

| 项 | axios | 本项目 |
|---|---|---|
| 表单 | 浏览器 `FormData` / node `form-data` | `FormData` 值类型 + 内置 multipart 编码 |
| `urlencoded` | 传 `URLSearchParams` 自动编码（对象 + 显式类型也会走序列化器） | `with_data_from_urlencoded(Json)`，复用 query 的序列化器；**只提供这一种约定**，别的约定自己拼 |
| `name` / `filename` 转义 | 不转义（node 实现） | 按 WHATWG 转义（防解析错位与注入） |
| `transformRequest` | 可插拔 | 固定为上述四种形态，不做转换器 |
| 流式上传 | 支持（Node 流） | 不支持，整块字节 |

## 注意

- 改 `Body` 的形态或 multipart 布局时，`serialize_body()`、`Config::to_string` 的渲染、
  `config/body_test.mbt` 的字节级用例与 `docs/03` 的表格要一起改；
- 想新增一种形态（例如原始二进制体 `with_data_from_bytes`），在 `config/body.mbt` 加一个变体、
  一个构建器、一处序列化分支与渲染分支即可；`merge_config` 不用动（它走「只取请求级」，与形态无关）。
