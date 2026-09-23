# easy-http-client：axios 风格 HTTP 客户端（MoonBit）

## 一、范围（按你的最新口径收敛）

**做**：实例创建（`create` / `Client::new` / `Client::create`）、通用 `request(config)`、配置合并（重点）。
**不做**：`get`/`post`/`put` 等快捷方法、拦截器、取消、重定向、proxy、transformRequest。快捷方法共用同一条管线，后续每个都是 3～5 行薄封装，设计上会留好位置。

已确认的关键调研结论：
- MoonBit 标准库（core）**没有任何网络能力**；唯一 HTTP 实现在 `moonbitlang/async/http`（最新 0.22.2），且是 **全异步** `async fn`。所以本库对外 API 也是 `async fn`。
- `async fn` 可以写在 `pub(open) trait` 里，并且能用 `&Trait` 特质对象字段调用 —— 这是本库「可替换传输层」这个 OOP 设计的地基（moonbitlang/async 自己就是这么写的：`parser.mbt` 里 `transport : &@io.Reader`）。
- 包间依赖不能成环 → 架构必须是 DAG。
- 内置 `Json` 类型、`@encoding/utf8`、`@encoding/base64`、`@encoding/percent` 都在 core 里，无需额外依赖。
- `pub using @pkg { ... }` 是再导出机制（`pub typealias` 在 core 里查无实例，不用）。

## 二、包结构（6 个包，依赖为无环 DAG）

```
easy-http-client/
├── moon.mod                       # 改 preferred_target = "native"; 加 moonbitlang/async@0.22.2
├── moon.pkg                       # 根包 = 门面 + 请求管线
├── client.mbt                     # Client / create / request
├── response.mbt                   # Response
├── error.mbt                      # HttpError / ErrorCode / ErrorInfo
├── pipeline.mbt                   # priv: 组装请求、解析响应、状态校验
├── facade.mbt                     # pub using 再导出 Config/Headers/Method...
├── easy-http-client_test.mbt      # async test，注入 MockTransport
│
├── config/                        # ① 纯逻辑 · 无网络依赖
│   ├── moon.pkg
│   ├── method.mbt                 # enum Method（9 个）+ derive(Eq, Hash, Debug)
│   ├── config.mbt                 # struct Config + Auth + ResponseType + with_* 构建器
│   └── default.mbt                # defaults()：axios 的内置默认值
│
├── headers/                       # ② 纯逻辑 · 大小写不敏感
│   ├── moon.pkg
│   └── headers.mbt                # struct Headers（字段 priv，不变量被封装）
│
├── merge/                         # ③ 纯逻辑 · 配置合并（重点）
│   ├── moon.pkg
│   ├── merge.mbt                  # 四种合并策略 + merge_config + flatten_headers
│   ├── json_merge.mbt             # Json 深合并（params 用）
│   └── merge_wbtest.mbt           # 白盒测试私有策略函数
│
├── url/                           # ④ 纯逻辑 · URL 与 query
│   ├── moon.pkg
│   ├── combine.mbt                # is_absolute_url / combine_urls / build_full_path
│   ├── encode.mbt                 # axios 风格的 percent 编码
│   └── build_url.mbt              # params(Json) → query string
│
└── transport/                      # ⑤ 唯一依赖 async 的包：可替换传输层
    ├── moon.pkg
    ├── transport.mbt              # trait Transport + PreparedRequest + RawResponse
    ├── async_http.mbt             # AsyncHttpTransport（包装 @http.request）
    └── mock.mbt                   # MockTransport（可编程，供测试与用户复用）
```

分层理由：`config` / `headers` / `merge` / `url` **完全不碰网络和 async**，可以用普通同步 `test` 块测试，跑得快且不依赖外网；async 依赖被关在 `transport` 一个包里。根包只做编排与对外 API。

## 三、数据模型（核心设计）

```moonbit
// ---- @config：所有字段都是 Option，None = 「未提供」，合并时向下回退 ----
pub(all) struct Config {
  // 策略 1 valueFromConfig2 —— 只取请求级，绝不从默认值继承
  url      : String?
  method   : Method?
  data     : Json?
  // 策略 2 defaultToConfig2 —— 请求级优先，否则回退默认值
  base_url     : String?
  timeout      : Int?              // 毫秒，0/None = 无超时
  response_type : ResponseType?
  // 策略 3 mergeDeepProperties —— 深合并（本项目里最能体现 axios 语义的部分）
  params : Json?
  auth   : Auth?
  headers        : Headers?                 // 请求级平铺 headers
  common_headers : Headers?                 // 默认值的 common 层
  method_headers : Map[Method, Headers]?    // 默认值的按方法层
  // 策略 4 mergeDirectKeys —— 请求级「存在即生效」
  validate_status : ((Int) -> Bool)?
  // 也走策略 3，默认 true
  allow_absolute_urls : Bool?
} derive(Default)

pub(all) struct Auth { username : String?; password : String? } derive(Eq, Debug)
pub(all) enum ResponseType { Auto; Json; Text } derive(Eq, Debug)
```

`Config` 同时支持两种写法：记录展开 `{ ..Config::default(), url: Some("/x") }`，以及链式构建器 `Config::default().with_base_url("https://api.example.com").with_timeout(5000)`（方法名统一加 `with_` 前缀，避免和字段访问撞名；方法上带可选参数已确认可用）。

```moonbit
// ---- @headers：大小写不敏感，不变量由 priv 字段封装 ----
pub struct Headers { priv entries : Map[String, String] }  // key 一律规范化为小写
pub fn Headers::new() -> Headers
pub fn Headers::set(Self, String, String) -> Self          // 返回新值，不可变风格
pub fn Headers::get(Self, String) -> String?               // 大小写不敏感查找
pub fn Headers::has / remove / length / entries
pub fn Headers::merge(Self, Self) -> Self                   // 入参覆盖自身
```
刻意简化：不实现 axios 「保留首次出现的大小写拼写」和 `false` 哨兵值（表示「禁止被覆盖」），在文档里写明。

```moonbit
// ---- @transport：OOP 亮点，传输层可整体替换 ----
pub(all) struct PreparedRequest {
  method : @config.Method
  url : String                // 已含 base_url 与 query
  headers : @headers.Headers  // 已拍平
  body : Bytes?
  timeout : Int?
}
pub(all) struct RawResponse { status : Int; status_text : String; headers : @headers.Headers; body : Bytes }

pub(open) trait Transport {
  async fn send(Self, PreparedRequest) -> RawResponse raise Error
}

pub struct AsyncHttpTransport  // 包装 @http.request，真发请求
pub struct MockTransport       // 记录收到的请求 + 返回预置响应
```

```moonbit
// ---- 根包：对外 API ----
pub struct Client {
  priv defaults  : @config.Config
  priv transport : &@transport.Transport
}
pub fn Client::new(config? : Config, transport? : &Transport) -> Client
pub fn Client::create(self, config : Config) -> Client        // 对应 axios 的 instance.create
pub async fn Client::request(self, config : Config) -> Response raise HttpError

pub fn create(config? : Config) -> Client                     // 对应 axios.create
pub fn default_client() -> Client

pub(all) struct Response {
  data : Json            // Auto/Json → 解析结果；解析失败降级为 Json::String(原文)
  status : Int
  status_text : String
  headers : Headers
  config : Config
  raw : Bytes            // 二进制原文始终保留
}
pub fn Response::text / json / is_success

pub(all) enum ErrorCode { BadRequest; BadResponse; Network; Timeout; InvalidUrl; NotSupported }
pub(all) struct ErrorInfo { message : String; code : ErrorCode; config : Config; response : Response? }
pub suberror HttpError { HttpError(ErrorInfo) }
pub fn HttpError::code / message / response / info
```

注：`Config` 含函数类型字段，不能 `derive(Debug)`，改为手写 `Debug`（`validate_status` 打印为 `<fn>`），测试里比对具体字段。

## 四、请求管线（`Client::request` 内部，严格照 axios 顺序）

1. `merged = @merge.merge_config(self.defaults, request_config)`
2. `method = merged.method.or(self.defaults.method).unwrap_or(Method::Get)` —— 复刻 axios 在 `_request` 里从 `this.defaults.method` 单独回退的行为
3. `full = @url.build_full_path(merged.base_url, merged.url, merged.allow_absolute_urls)`；无 url 或非绝对 URL 且无 base_url → `raise HttpError(InvalidUrl)`
4. `final_url = @url.build_url(full, merged.params)`
5. `headers = @merge.flatten_headers(common_headers, method_headers[method], headers)` —— 优先级 common < 按方法 < 请求级平铺
6. body：`Json` → JSON 字符串（若无 `Content-Type` 则补 `application/json`）；`Json::String` → 原文
7. `auth` 存在时补 `Authorization: Basic <base64>`
8. `transport.send(prepared)`；`timeout` > 0 时用 `@async.with_timeout` 包裹，超时映射为 `ErrorCode::Timeout`
9. 按 `response_type` 解析（`Auto` = 尝试 `@json.parse`，失败降级为字符串，对齐 axios 的 `forcedJSONParsing`）
10. `validate_status`（默认 2xx）：失败 → `raise HttpError`，4xx → `BadRequest`，5xx → `BadResponse`（复刻 axios `settle.js` 的 `Math.floor(status/100) - 4`），并把 `response` 挂在错误上

## 五、配置合并规范（要写进 README 的对照表）

| 字段 | axios 策略 | 本项目行为 |
|---|---|---|
| `url` / `method` / `data` | `valueFromConfig2` | 只取请求级，默认值里的同名字段被丢弃 |
| `base_url` / `timeout` / `response_type` | `defaultToConfig2` | 请求级优先，否则回退默认 |
| `params` / `auth` | `mergeDeepProperties` | 深合并；`Auth` 逐字段、`Json` 逐 key 递归 |
| `headers` | caseless 深合并 | key 大小写不敏感，请求级覆盖 |
| `common_headers` / `method_headers` | 深合并 + 拍平 | common < 按方法 < 平铺 |
| `validate_status` | `mergeDirectKeys` | `Some(_)` 存在即生效 |
| 数组 | 替换而非拼接 | `params` 里的数组整个替换，不 concat |
| `None` | `undefined` 语义 | 一律「未提供」，向下回退，不覆盖 |

`params` 序列化按 axios 默认行为：数组 → `b[]=x&b[]=y`、嵌套对象 → `c[d]=2`、`null` 跳过、空格编码为 `+`、`! ' ( ) ~` 一并转义、URL 已带 `?` 用 `&` 拼接、`#` 之后的内容先剥离。`is_absolute_url` 用 `^([a-z][a-z\d+\-.]*:)?//` 的等价手写扫描（core 无 regex），`combine_urls` 去掉 base 尾部斜杠与相对路径开头斜杠后恰好补一个 `/`。

## 六、执行步骤

0. **前置验证**（先做，风险最高）：`moon add moonbitlang/async@0.22.2`；写一个最小 `async fn` + 一个引用 `@easy-http-client` 的黑盒测试，确认依赖能拉到、async 在 native 上能编译、包别名可用、`{ ..Config::default(), f: v }` 记录展开能过编译。任何一项失败就地调整（详见风险）。
1. `config` 包 → `moon test -p q2316368843/easy-http-client/config`
2. `headers` 包 → 大小写不敏感、覆盖、合并优先级
3. `url` 包 → 绝对 URL 判定、斜杠拼接、params 序列化与编码（对照表逐条测试）
4. `merge` 包 → 四种策略逐条断言，含「数组替换而非拼接」「auth 逐字段深合并」「None 回退」
5. `transport` 包 → trait + Mock + AsyncHttpTransport（真发请求的部分放最后）
6. 根包 → `Client` / `pipeline` / `Response` / `HttpError`；黑盒 `async test` 注入 MockTransport 覆盖整条管线（含 4xx/5xx 错误映射、base_url 拼接、header 拍平顺序）
7. `facade.mbt` 的 `pub using` 再导出，确认 `.mbti` 里类型对使用者可见
8. `cmd/main/main.mbt` 替换掉模板的 `Math`，改成真实请求的可运行示例
9. README：用法示例 + 上面那张合并语义对照表 + 明确列出「暂不支持：快捷方法/拦截器/取消/重定向/proxy」
10. `moon info && moon fmt`，检查 `.mbti` 与格式化 diff；`moon test` 全量；`moon run cmd/main` 走一次真实网络；`moon coverage analyze > uncovered.log` 查漏

全程遵守 AGENTS.md：`///|` 分块、文件按职责拆分、测试用 `assert_eq`/`debug_inspect`。

## 七、风险与预案

1. **`moon add` 依赖拉取失败**（离线）：先完成 `config`/`headers`/`merge`/`url` 四个纯逻辑包 + `Transport` trait + MockTransport（占工作量 ~80%，且可完整测试），`AsyncHttpTransport` 放最后单独补。
2. **`@http.request` / `@async.with_timeout` 的确切签名**（是否需要 `Client` 实例、`&@io.Data` 空 body 怎么传、超时函数的 raiser 类型）：实现第 5 步时先读 `moonbitlang/async` 源码确认，不靠猜。
3. **`preferred_target` 从 wasm 改 native** 后 `moon build`/`moon test` 默认目标变了：第 0 步验证一遍；若你之后还要 wasm（web playground），再加 `supported_targets` 或按需 `moon build --target wasm`。
4. **`pub using` 再导出 trait** 的语法未确认（core 里只见 `type` 与函数的再导出）：若 trait 不能这样再导出，自定义传输层的使用者改为直接 import `@easy-http-client/transport`，其余类型仍走门面。
5. **`Map` 无 `copy()`** 导致 `Headers::set` 返回新值需要手动重建 Map：若无 `copy()` 就用迭代重建，或退化为内部 `mut` + 拷贝构造。

## 八、验收标准

- `moon check` / `moon test` 全绿（`.githooks/pre-commit` 跑的就是 `moon check`）。
- 四个纯逻辑包无任何 async/网络依赖，可离线测试；合并语义对照表里每一行都有对应断言。
- `moon run cmd/main` 能对真实公网地址发出 `request` 并打印状态码、响应头、解析后的 JSON。
- `Client::create` 派生出的新实例正确继承父实例默认值，再叠加本次配置。
- `.mbti` diff 只包含预期的公开 API。