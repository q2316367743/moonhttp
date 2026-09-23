# easy-http-client

axios 风格的 MoonBit HTTP 客户端。当前实现聚焦三件事：**创建实例**、**通用 `request`**、**配置合并**。

设计上刻意留出扩展点（可替换的传输层、`instance.create` 派生），但暂不实现拦截器、取消、重定向等 axios 高级特性——详见文末「暂不支持」。

```moonbit nocheck
///|
async fn main {
  // 创建实例：base_url 与公共头写在实例默认配置里，后续请求不必重复设置
  let api = @easy-http-client.create(
    @easy-http-client.Config::default()
      .with_base_url("https://api.github.com")
      .with_timeout(5_000)
      .with_common_header("Accept", "application/vnd.github+json"),
  )

  // 发请求：配置在「内置默认值 → 实例默认值 → 本次请求」之间按 axios 的规则合并
  let res = api.request(
    @easy-http-client.Config::new("/repos/moonbitlang/core")
    .with_params({ "per_page": 3 }),
  )

  println(res.status) // 200
  println(res.headers.get("content-type")) // application/json; charset=utf-8
  println(res.data.stringify()) // 解析好的 JSON 对象
  println(res.text()) // 原始响应文本
}
```

## 安装

```bash
moon add q2316368843/easy-http-client
```

`moon.mod` 里会记录：

```toml
import {
  "q2316368843/easy-http-client@0.1.0",
}
```

本项目默认构建目标是 `native`。网络能力来自官方异步库 `moonbitlang/async`（当前版本 `0.22.2`），它在 native 后端最成熟。

## 快速开始

完整可运行示例见 [`src/cmd/main/main.mbt`](src/cmd/main/main.mbt)，用 `moon run src/cmd/main` 执行（需要联网）。它演示了文本响应、JSON 响应、查询参数、实例派生与错误处理。

## 配置合并语义

这是本项目的重点。行为严格对齐 axios `lib/core/mergeConfig.js`，但 MoonBit 没有运行时反射，因此不采用「字段 → 合并函数」查表，而是**每个字段显式写出它用哪一档策略**——打开 [`src/merge/merge.mbt`](src/merge/merge.mbt) 就能一眼看到每个字段的归属。

| 字段 | axios 策略 | 本项目行为 |
|---|---|---|
| `url` / `http_method` / `data` | `valueFromConfig2` | **只取请求级**。默认值里的同名字段被丢弃，即使请求没提供也不回退 |
| `base_url` / `timeout` / `response_type` | `defaultToConfig2` | 请求级优先，缺省则回退默认值 |
| `params` | `mergeDeepProperties` | 按 JSON 对象逐键递归合并；数组**整体替换而非拼接** |
| `auth` | `mergeDeepProperties` | 逐字段合并：默认值给 `username`、请求给 `password`，两者都在 |
| `headers` | caseless 深合并 | 头名大小写不敏感；请求级同名头覆盖默认值，默认值独有的头保留 |
| `common_headers` / `method_headers` | 深合并 + 拍平 | 优先级 `common` < 按方法 < 请求级平铺，逐层覆盖 |
| `allow_absolute_urls` | `mergeDeepProperties` | 标量上的深合并退化为「请求级有就用请求级」 |
| `validate_status` | `mergeDirectKeys` | 请求级提供即整体接管；缺省沿用默认的 2xx 规则 |
| 任何字段的 `None` | `undefined` | 一律表示「未提供」→ 回退，而不是覆盖 |

几个刻意的细节：

- **`http_method` 而不是 `method`**：`method` 是 MoonBit 的保留字，用作字段名会告警，也会影响使用者写记录字面量。构建器仍是 `with_method`（参数类型 `Method` 已说明语境），`Config::to_string()` 的标签也沿用 `method`，便于和 axios 文档逐项对照。
- **想关掉状态码校验**：axios 靠给 `validateStatus` 传 `null`（`mergeDirectKeys` 连 `undefined` 都算「存在」）。本项目传一个恒真函数即可：`with_validate_status(fn(_) { true })`。删掉这个字段只会退回默认的 2xx 规则。
- **方法缺省时的回退顺序**：`合并结果 → 实例默认值 → GET`。合并阶段 `http_method` 走「只取请求级」策略，所以 axios 也在 `_request` 里单独从 `this.defaults.method` 回退一次，本项目复刻了这个行为。

## 请求管线

`Client::request` 内部顺序与 axios 一致：

1. `merge_config(实例默认值, 请求配置)`
2. 确定请求方法（缺省回退到实例默认值，再回退到 `GET`）
3. `base_url` + `url` 拼成完整地址，再追加序列化后的 query
4. 三层头拍平成一份（`common` < 按方法 < 请求级平铺）
5. 序列化 body：`Json::String` 原样发送，其它 JSON 值序列化成 JSON 文本并补 `Content-Type`；有 `auth` 则补 `Authorization`
6. 交给传输层发送（`timeout > 0` 时套超时）
7. 按 `response_type` 解析响应体
8. 用 `validate_status` 校验状态码，失败则抛 `HttpError`

第 3～8 步的实现分别在 [`src/url/`](src/url/)、[`src/pipeline.mbt`](src/pipeline.mbt) 里，全部是纯函数，可以脱离网络单独测试。

### URL 与 query 的边界行为

- 绝对地址判定等价于 axios 的 `/^([a-z][a-z\d+\-.]*:)?\/\//i`：`//cdn.example.com/x` 算绝对地址，而 `localhost:8080/x` **不**算（冒号后不是 `//`），会正常和 `base_url` 拼接。
- `combine_urls` 去掉 base 的尾斜杠与相对路径的首斜杠，中间补恰好一个 `/`。
- query 序列化按 axios 默认的 `paramsSerializer`：
  - 数组 → `tags%5B%5D=a&tags%5B%5D=b`（**方括号会被百分号编码**，这是 axios 的真实输出）
  - 嵌套对象 → `filter%5Bstatus%5D=1`；数组里套对象 → `items%5B0%5D%5Bid%5D=1`
  - `null` 一律跳过，既不写 `key=` 也不写 `key=null`
  - 空格写成 `+`；保留下来的字符集是 `A-Za-z0-9-_.*`，`~` 反而要转义成 `%7E`（对齐 `encodeURIComponent` + axios 的额外转义表）
  - URL 里已有 `?` 时用 `&` 续接；`#fragment` 会被丢弃（axios 也是先截断再拼 query）
- 数字参数优先使用 `Json::Number` 里保存的原始字面量（`repr`）：`@json.parse` 对超出 `Double` 精度的大整数会填上它，从而避免 `123456789012345678901234567890` 被写成 `1.2345678901234568e+29`；没有 `repr` 时退回 `Double` 的最短表示（`1.0` 写成 `1`）。

## 可替换的传输层

真正「把字节发出去」这一步被抽象成 `Transport` trait，整个 `moonbitlang/async` 依赖只存在于 [`src/transport/async_http.mbt`](src/transport/async_http.mbt) 一个文件里。带来的好处：

- `config` / `headers` / `merge` / `url` 四个包不依赖网络与异步，可以用普通同步测试覆盖；
- 使用方可以注入自己的实现，测试时不必真的联网。

```moonbit nocheck
// 测试里替换掉真实网络：Mock 会记录收到的请求，并返回预置响应
let mock = @transport.MockTransport::new(response)
let transport : &@transport.Transport = mock
let client = @easy-http-client.Client::new(transport=transport)

ignore(client.request(@easy-http-client.Config::new("/users")))
let sent = mock.last_request().unwrap()
println(sent.url)                  // 已经拼好 base_url 与 query 的完整地址
println(sent.headers.to_string())  // 已经拍平的头
```

自定义传输只需要实现一个方法：

```moonbit nocheck
///|
pub impl Transport for MyTransport with fn send(self, request) {
  // request : PreparedRequest（方法、完整 URL、已拍平的头、body、超时）
  // 返回 RawResponse（状态码、状态短语、响应头、响应体字节）
  ...
}
```

## 错误处理

`request` 失败时抛出 `HttpError`，它携带分类、已合并的配置、以及（若服务端已响应）原始响应：

```moonbit nocheck
try {
  ignore(api.request(config))
} catch {
  @easy-http-client.HttpError(info) => {
    println(info.code)                          // ERR_BAD_REQUEST
    println(info.message)                       // 请求失败，状态码 404
    println(info.response.unwrap().status)      // 404
    println(info.config.url)                    // 出错时的配置，便于定位
  }
}
```

| `ErrorCode` | axios 对应错误码 | 触发时机 |
|---|---|---|
| `BadRequest` | `ERR_BAD_REQUEST` | 状态码 4xx 且未通过校验 |
| `BadResponse` | `ERR_BAD_RESPONSE` | 状态码 5xx（或其它非 2xx）；强制 JSON 解析失败 |
| `Network` | `ERR_NETWORK` | 连接失败、DNS 解析失败、TLS 握手失败等 |
| `Timeout` | `ECONNABORTED` | 超过 `timeout`（axios 默认也用 `ECONNABORTED`） |
| `InvalidUrl` | `ERR_INVALID_URL` | 既没有 `url` 也没有可用的 `base_url` |
| `NotSupported` | `ERR_NOT_SUPPORT` | 传输层无法完成该请求 |

## 包结构

六个包构成无环依赖，每个包只依赖它真正需要的下层：

```
easy-http-client/
└── src/                     业务代码全部在 src/ 下（根目录只放模块元数据与文档）
    ├── (根包)               门面 + 请求管线：Client / create / request / Response / HttpError
    ├── config/              配置形状、Method、内置默认值、with_* 构建器
    ├── headers/             大小写不敏感的 Headers
    ├── merge/               配置合并（四种策略）与头拍平
    ├── url/                 绝对地址判定、拼接、params 序列化
    ├── transport/           Transport trait + AsyncHttpTransport + MockTransport
    └── cmd/main/            可运行示例
```

约定：凡是出现在公开签名里的类型，都在定义它的包里**再导出一次**（`pub using`），根包也再导出一份。所以日常使用只需要 `@easy-http-client` 一个 import。

## 暂不支持

以下 axios 能力本版本**没有**实现，配置里也不会出现对应字段（避免「配置了但完全不生效」）：

- `get` / `post` / `put` / `delete` / `head` / `options` / `patch` 等快捷方法（都是 `request` 的薄封装，见「后续扩展」）
- 拦截器（`interceptors`）、取消（`CancelToken` / `signal`）
- 自动跟随重定向（`maxRedirects`）、代理（`proxy`）
- 上传/下载进度（`onUploadProgress` / `onDownloadProgress`）
- 请求/响应转换器（`transformRequest` / `transformResponse`）——目前 body 序列化与响应解析固定为内置行为
- `withCredentials` / `xsrfCookieName` / `xsrfHeaderName`（本项目不管理 cookie）
- 响应 cookie：底层的响应 cookie 单独存放，没有并入 `headers`，所以读不到 `Set-Cookie`
- 连接复用：每次请求新建连接
- 单条头的多值：一个头名只能对应一个字符串值（axios 允许数组）

### 与 axios 的其它差异

- `Config` 的 `method` 字段在本项目里叫 `http_method`（保留字原因，见上文）。
- `Headers` 内部以小写保存头名（写入时的原始拼写会被记住并用于输出），但不支持 axios 用 `false` 表示「禁止被同名默认值覆盖」的哨兵值。
- `Response::data` 是 `Json`：解析失败时是 `Json::String(原文)`，等价于 axios 的 `forcedJSONParsing` 行为；二进制内容请读 `Response::raw`。
- 没有可变的全局默认值。axios 的全局 `axios.defaults` 在本项目里对应 `@config.defaults()`（固定的内置默认值）；要定制请用 `create(...)` 或 `client.create(...)` 派生。

### 后续扩展

`request` 已经是完整的通用入口，各快捷方法只是在它之上固定方法名与 body 的位置，例如：

```moonbit nocheck
///|
pub async fn Client::get(
  self : Client,
  url : String,
  config? : Config,
) -> Response raise HttpError {
  let config = match config {
    Some(config) => config
    None => Config::new(url)
  }
  // with_url 已经由 Config::new 完成；这里只需补上方法
  self.request(config.with_method(Method::Get))
}
```

## 开发

```bash
moon check              # 类型检查（pre-commit 钩子跑的就是它）
moon test               # 全部测试
moon test -p q2316368843/easy-http-client/merge   # 只跑某个包
moon run src/cmd/main   # 真实网络示例
moon info && moon fmt   # 更新 .mbti 接口文件并格式化
moon coverage analyze   # 覆盖率
```

测试分层：`config` / `headers` / `merge` / `url` 四个包是纯逻辑，用同步测试逐条钉住合并语义；根包与 `transport` 用 `async test` 配合 `MockTransport` 跑完整管线，不依赖外网。真实网络只在 `src/cmd/main` 里使用。

维护者文档（实现思路、API 契约、改动清单、MoonBit 语言坑位）见 [`docs/`](docs/README.md)。
