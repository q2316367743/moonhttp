# 01 架构与分层

## 目录结构

```
moonhttp/
├── moon.mod                     模块元数据（source = "src"，业务代码全在 src/ 下）
├── README.mbt.md                使用者文档（README.md 是指向它的符号链接）
├── docs/                        本目录：维护者文档
└── src/
    ├── moon.pkg                 根包：门面与编排（依赖下方全部）
    ├── client.mbt               Client 与三个入口（request / stream / sse）+ 两个工厂
    │                            + 接壤层（拼请求、拼 Response）
    ├── http_error.mbt           错误契约：ErrorCode / ErrorInfo / HttpError 与**所有**抛错点
    ├── facade.mbt               门面层：Response / StreamResponse / SseStream 等
    │                            对外响应类型 + pub using 再导出
    ├── *_test.mbt               根包黑盒测试（用 MockTransport 跑整条管线）
    ├── *_wbtest.mbt             根包白盒测试（覆盖只能从包内部触达的分支）
    ├── config/                  配置的形状、合并契约、默认值、构建器与请求体序列化
    ├── headers/                 大小写不敏感的 Headers
    ├── sse/                     SSE 事件解析（纯逻辑：吃字节、吐事件）
    ├── url/                     绝对地址判定、拼接、params 序列化
    ├── util/                    纯函数层：拼请求、解码、Content-Type 与状态码判定
    ├── transport/               传输层：trait + 真实实现 + Mock + 响应体流
    └── cmd/main/                可运行示例（真实网络）
```

**为什么根目录的文件多，而测试文件不能挪到 `tests/` 之类的子目录**：MoonBit 的约定是「一个目录 = 一个包」，测试文件按**所在目录的包**归属——`src/foo_test.mbt` 是 `src` 这个包的黑盒测试，`src/foo_wbtest.mbt` 是它的白盒测试（白盒测试会被编进包里才能看见 `priv`，物理上不可能在别处）。把它们移进子目录，它们就变成了「一个新包的测试」，与被测的包再无关系。

**为什么这些代码只能待在根包（`client.mbt` / `http_error.mbt` / `facade.mbt`），而不能整体搬进一个 `client/` 子包**：两层原因，第二层是实测出来的硬限制。

第一层是包间不能成环。`Client` 抛 `HttpError`、又返回 `Response` / `StreamResponse` / `SseStream`，两个流式类型的方法也抛 `HttpError`，`HttpError` 带 `Response`——这几个类型互相引用，构成一个强连通块，必须同属一个包。而根包要能用 `@moonhttp.Client` / `@moonhttp.default_client()`，`Client` 就必须定义在根包里（`pub using` 能再导出**类型与函数**，但包一旦 import 一个反过来 import 自己的包就成环）。

第二层是 `pub using` 再导出不了**错误构造子**，这是决定性的：

| 试法 | 编译器结果 |
|---|---|
| `pub using @client {type HttpError}` | 类型可用，但 `catch { @moonhttp.HttpError(info) }` 报 `Value HttpError not found in package 'moonhttp'` |
| `pub using @client {HttpError}`（裸名当值） | `Alias for the type '@client.HttpError' should be created via 'using @client {type HttpError}'` |
| `pub using @transport {type TransportError, Timeout, Network, Unsupported}`（构造子名与类型名不同的对照） | `The type/trait @transport.Timeout is not found`——`using` 列表里的裸名只按**类型 / trait** 解析，根本不认错误构造子 |
| `pub type HttpError = @client.HttpError`（类型别名） | 同样只带类型，不带构造子 |

也就是说，只要 `HttpError` 定义在子包里，`catch { @moonhttp.HttpError(info) => ... }` 这个写法就必然失效（只能改成 `catch { error => error.code() / error.message() }` 这种访问器写法，要解构就得额外 `import @moonhttp/client`）。`http_error.mbt` 里把它声明成 `pub(all) suberror` 就是为了让调用方能解构，这个代价换一个「根包更干净」不值得——**所以不要再尝试把这些代码搬进子包**（拆文件是可以的，见下）。

**能干净独立出去的是「签名里不出现门面类型」的纯逻辑**——`sse/` 就是这么出去的（`config` / `headers` / `url` 同理），根包里的纯函数同理，它们现在都在 `util/` 包里：`resolve_method` / `basic_auth` / `build_prepared_request` / `decode_body` / `media_type` / `declares_event_stream` / `status_allowed`。

判据落在**签名**上，不是「感觉像工具函数」：只要返回 `Response` 或抛 `HttpError`，就必须留在根包——`util` 一旦反过来依赖根包就成环。所以 `prepare_request` / `build_response` 留在 `client.mbt`，`transport_error` / `status_error` / `status_error_code` / `validate_response` 与错误类型一起待在 `http_error.mbt`，它们正是「与门面类型接壤」的那一层；`util` 的准入条件写在 `src/util/moon.pkg` 里，往里加东西前先看那一条。

`build_prepared_request` 是这条判据下唯一需要改造才搬得动的：它原来用 `raise HttpError` 报「地址不可用」，搬进 `util` 后改成返回 `Option`（`None` = 地址不可用），由根包的 `prepare_request` 翻译成 `InvalidUrl` 错误——错误码与文案属于对外契约，留在根包。这与 `@url.build_full_path` 返回 `Option`、根包负责报错的分工完全一致。

**根包有三个源文件**：`client.mbt`（`Client` + 三个入口 + 接壤层）、`http_error.mbt`（错误类型与所有抛错点）、`facade.mbt`（对外响应类型与再导出）。三者都用上了 RL-04 为根包文件开出的例外（≤ 1000 行，需在文件头声明）。

**同包拆文件是免费的**：同目录 = 同包，拆文件既不成环、也不影响 `pub` / `priv` 的可见性，`.mbti` 一个字都不会变——所以「文件太长」永远可以靠拆文件解决，不必动包结构。跨包才有代价（`HttpError` 就是被这一条钉在根包里的，理由见上）。**例外只给根包**：子包仍守 300 行（`util/` 两个文件各不足 100 行，`config` / `sse` / `transport` 里的文件超了就必须拆）。

## 依赖方向（无环）

MoonBit 的包之间不能循环依赖，所以分层是按「数据从谁流向谁」切开的：

```
config ──────┐
headers ─────┼─→ util ──┐
url ─────────┤          │
transport ───┘          ├─→ （根包：门面 + 编排）──→ Client / request / stream / sse
sse ────────────────────┘
```

- `config` 依赖 `headers`（配置里有头字段），并且自己带着**合并契约**（`config/merge.mbt`）：
  `Config.data` 是私有字段，跨包连记录字面量都写不出来，所以合并必须与 `Config` 同包（理由见 `02-config-merge.md`）；
- `url` 不依赖任何本项目的包（只吃字符串和 `Json`）；
- `sse` 也不依赖本项目的包（只吃字节），所以它是这层里唯一能被任意字节来源复用的包；
- `transport` 依赖 `config` 与 `headers`（`PreparedRequest` 的字段类型），**并且是唯一依赖 `moonbitlang/async` 的包**；
- `util` 依赖 `config` / `headers` / `url` / `transport`（拼请求要用到它们），但它不认识任何门面类型——这正是它能待在根包外面的唯一理由；
- 根包依赖以上全部，负责编排与对外 API。

## 关键设计决策

### 1. async 依赖被关在一层里

MoonBit 标准库没有任何网络能力，唯一的 HTTP 实现在 `moonbitlang/async/http`，且是**全异步**的。如果把异步调用散在代码里，配置合并、URL 拼接这些纯逻辑也要跑在异步环境里才能测。

因此把「真的把字节发出去」抽成 `Transport` trait，异步实现只存在于 `src/transport/` 这个包里（`async_http.mbt` 是真实传输，`stream.mbt` 是响应体流）。收益：

- `config` / `headers` / `url` / `util` 四个包可以用**普通同步测试**覆盖，跑得快、不依赖网络；
- 根包的管线测试用 `MockTransport` 注入，能确定性复现 4xx/5xx、超时、读到一半失败等分支；
- 响应体是流（`ResponseBody`），但它的读语义在内存体与真实连接上完全一致，Mock 因此能代表网络侧的流式行为；
- 使用方也能替换传输层（自定义实现只需一个方法）。

同一把尺子也决定了 SSE 解析的位置：它只吃字节、不碰 async，所以独立成 `sse` 包，用同步测试覆盖规范逐条（`src/sse/sse_test.mbt`）。传输层只负责把字节交出来，「字节怎么解」是上层的事；而「怎么把字节喂给解析器」是根包里 `SseStream` 的事（`facade.mbt`）。

### 2. 配置是值语义 + `Option` 字段

`Config` 的所有字段都是 `Option[T]`，`None` = 「未提供」。这是复刻 axios `mergeConfig` 的前提：axios 用 JS 的 `undefined` 表达同一件事，而 `null`/`undefined` 与「显式给了个值」必须能区分开，否则会丢掉「回退到默认值」这条规则。

配套约定：所有变更方法（`with_*`、`Headers::set`、`Client::create`）都**返回新实例**，不就地修改。`Config` 会被多个实例共享（`Client::create` 派生时），一旦有就地修改就会出现「改 A 影响 B」的幽灵 bug。

### 3. 类型在定义它的包里再导出

MoonBit 的 import 是包级的：`Config` 的字段类型 `Headers` 定义在另一个包里，使用者若要用 `Config` 就得 import 两个包。为此确立约定：

> 凡是出现在公开签名里的类型，都在**用到它**的那个包里用 `pub using` 再导出一次，本包代码因此能写裸名（`config` / `headers` / `transport` / `util` 都这么干）；根包（`src/facade.mbt`）再对使用者导出一份。

所以日常使用只需要 `@moonhttp` 一个 import。

## 怎么扩展

### 新增一个配置字段（最常见）

1. `src/config/config.mbt` 的 `Config` 加字段（`Option[T]`），文档注释里写明它在哪一档合并策略下；
2. `src/config/config.mbt` 加 `with_*` 构建器（若使用者需要设置它）；
3. `src/config/render.mbt` 的 `Config::to_string` 里加一行渲染（可选，但有助于排查）；
4. `src/config/merge.mbt` 的 `merge_config` 里**显式**选择一档策略调用，并在注释里说明为什么是这一档（漏了是编译错误：记录字面量必须列全字段）；
5. 若它参与请求构造，接到 `src/util/request.mbt` 的 `build_prepared_request`（拼地址/头/body）或 `src/client.mbt` 的 `build_response`（解码已有 `src/util/response.mbt` 的 `decode_body`）；
6. 补测试：`src/config/merge_test.mbt` 测合并语义，根包 `src/*_test.mbt` 测端到端效果；
7. 更新 `docs/02-config-merge.md` 的字段归属表。

### 新增一种请求体形态（如原始二进制体）

见 `07-request-body.md` 末尾：在 `config/body.mbt` 加一个 `Body` 变体、一个构建器、一处序列化分支与一处渲染分支；
`merge_config` 不用动（请求体走「只取请求级」，与形态无关）。

### 新增一个快捷方法（如 `get` / `post`）

不要复制管线逻辑，只在 `Client` 上加薄封装后转调 `request`：

```moonbit
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

### 自定义传输实现（例如给测试用的假响应）

```moonbit
pub impl Transport for MyTransport with fn send(self, request) {
  // request : PreparedRequest；返回 RawResponse
  // 响应体是流：手里已经有完整字节时用 from_bytes 包一层
  {
    status: 200,
    status_text: "OK",
    headers: Headers::new(),
    body: ResponseBody::from_bytes(b"{}"),
  }
}
```

注意实现里的方法写 `fn` 而不是 `async fn`：异步性是 trait 声明的一部分，实现侧不重复标注（详见 `05-transport.md`）。

## MoonBit 语言注意事项（踩过的坑）

写这个项目时遇到的、非显而易见且会影响设计的语言行为，集中记录：

| 现象 | 处理方式 |
|---|---|
| `method` 是保留字，用作字段名/局部变量名都会告警 | 字段命名 `http_method`，局部变量用 `meth`；构建器仍叫 `with_method` |
| `pub impl` 才对外可见：不带 `pub` 的 `impl` 外部包看不到（黑盒测试也算外部） | 所有要给外部用的 `impl` 都写 `pub impl` |
| `pub suberror` 不导出构造子，外部无法构造也无法按构造子匹配 | 需要外部构造/匹配时写 `pub(all) suberror`（如 `HttpError`、`TransportError`） |
| 派生 / 手写的 trait impl 会被「隐式挂成常规方法」，该行为已废弃并告警 | 每个 `impl`/`derive` 后跟一条 `pub extend T with Trait::{...}` 显式声明 |
| `Json`、`Null` 等是只读类型，外部不能直接构造构造子 | 用 `Json::null()` / `Json::object(map)` 等公开构造器 |
| trait 里的 `async fn`，在 `impl` 里写 `fn` | 见上表与 `05-transport.md` |
| 泛型函数签名是 `fn[T] f(...)`，不是 `fn f[T](...)` | — |
| 同一类型上不能有同名方法（不支持重载），报 `The method X for type Y has been defined` | 想加 `request(url)` 这类重载行不通；本项目改为在 `Config` 侧提供 `Config::new(url)` 来缩短调用点 |
| 枚举变体的具名字段（如 `Json::Number(Double, repr~ : String?)`）不能用位置模式匹配 | 用 `Number(n, repr~)` 或 `Number(n, repr=repr)`；写位置模式会报参数个数错误 |
| `@json.parse` 只在 `Double` 无法精确表示时才填 `Json::Number` 的 `repr`（例如超大整数） | 序列化数字时优先用 `repr`，否则用 `Double` 的最短表示；见 `src/url/build_url.mbt` |
| 一个目录一个包，包间不能循环依赖 | 分层方向见上文 |
| 可选参数是**具名**的，不能按位置传 | 用 `Trait::method(self, start=0, end=n)` 这类具名实参（写成 `method(self, 0, n)` 会报「只接受 1 个位置参数」）。本项目统一用具名实参调用可选参数：`Client::new(transport=transport)`、`body.read_some(max_len=2)` |
| 顶层 `enum` / `struct` 不加 `priv` 会出现在 `.mbti` 里 | 纯内部类型（`BodyInner`、`MemoryBody`）必须标 `priv`，否则会污染公开接口——`moon info` 后能从 `.mbti` 的 diff 里看出来 |
| `pub(all) struct` 里允许个别字段标 `priv` | 三个门面类型都靠这条：`StreamResponse` / `SseStream` 的响应体流私有（读取必须走本类型的方法，错误才能统一成 `HttpError`）、`Response` 的 `raw` 私有（读法收敛到 `bytes()` / `text()` / `json()` 三个入口，解码规则只有一个落点）；`Config.data` 同理（请求体只能经三个构建器设置） |
| **私有字段会让跨包的记录字面量 / 记录展开失效**：`{ ..config, x: ... }` 报 `Cannot use struct update syntax on struct Config because it has private fields` | 一旦某个字段私有，别的包就既不能按名字段构造、也不能用记录展开，构造只能走构建器。两个落地后果：`merge_config` 必须与 `Config` 同包（`config/merge.mbt`）；根包回填方法只能写 `merged.with_method(...)` 而不是 `{ ..merged, http_method: ... }`。包内不受影响（`Config::new`、`with_*` 都是包内记录展开），要测包内写法得用白盒测试（`config/config_wbtest.mbt`） |
| `errdefer` 在 async 函数里同样有效，适合「失败就关连接」这类清理 | 传输层用它保证建连之后的任何失败都关闭连接；比 `try ... catch { cleanup; raise }` 更短，也不会触发 `fragile_catch_all` 告警 |
| 含 `mut` 字段的结构体，其内部变异**能穿过值类型字段可见**——把这种类型放进另一个结构体当普通字段（不标 `mut`）也照样生效 | `StreamResponse` 里的 `priv parser : SseParser` 就没标 `mut`：`next_event` 反复调 `parser.push` 能累积状态（`facade.mbt` 里的 `StreamResponse`）。给字段标 `mut` 反而会收到 `unused_mut` 告警——编译器认定这个 `mut` 没被用到，因为根本没有对该字段的整体赋值 |
