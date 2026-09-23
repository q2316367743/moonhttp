# 01 架构与分层

## 目录结构

```
moonhttp/
├── moon.mod                     模块元数据（source = "src"，业务代码全在 src/ 下）
├── README.mbt.md                使用者文档（README.md 是指向它的符号链接）
├── docs/                        本目录：维护者文档
└── src/
    ├── moon.pkg                 根包：门面 + 请求管线
    ├── client.mbt               Client / create / create() 派生 / request / stream
    ├── pipeline.mbt             纯函数管线：拼请求、解析响应、校验状态码
    ├── response.mbt             Response 与它的便捷方法
    ├── stream_response.mbt      StreamResponse：不读 body 的流式响应
    ├── error.mbt                HttpError / ErrorCode / ErrorInfo
    ├── facade.mbt               pub using 再导出
    ├── *_test.mbt               根包黑盒测试（用 MockTransport 跑整条管线）
    ├── config/                  配置的形状、默认值与构建器
    ├── headers/                 大小写不敏感的 Headers
    ├── merge/                   配置合并（四种策略）与头拍平
    ├── url/                     绝对地址判定、拼接、params 序列化
    ├── transport/               传输层：trait + 真实实现 + Mock + 响应体流
    └── cmd/main/                可运行示例（真实网络）
```

## 依赖方向（无环）

MoonBit 的包之间不能循环依赖，所以分层是按「数据从谁流向谁」切开的：

```
config ──┐
headers ─┼─→ merge ──┐
url ─────┘           ├─→ （根包：门面 + 管线） ──→ Client / request
transport ───────────┘
```

- `config` 依赖 `headers`（配置里有头字段）；
- `merge` 依赖 `config` 与 `headers`（要合并配置、拍平头）；
- `url` 不依赖任何本项目的包（只吃字符串和 `Json`）；
- `transport` 依赖 `config` 与 `headers`（`PreparedRequest` 的字段类型），**并且是唯一依赖 `moonbitlang/async` 的包**；
- 根包依赖以上全部，负责编排与对外 API。

## 关键设计决策

### 1. async 依赖被关在一层里

MoonBit 标准库没有任何网络能力，唯一的 HTTP 实现在 `moonbitlang/async/http`，且是**全异步**的。如果把异步调用散在代码里，配置合并、URL 拼接这些纯逻辑也要跑在异步环境里才能测。

因此把「真的把字节发出去」抽成 `Transport` trait，异步实现只存在于 `src/transport/` 这个包里（`async_http.mbt` 是真实传输，`stream.mbt` 是响应体流）。收益：

- `config` / `headers` / `merge` / `url` 四个包可以用**普通同步测试**覆盖，跑得快、不依赖网络；
- 根包的管线测试用 `MockTransport` 注入，能确定性复现 4xx/5xx、超时、解析失败等分支；
- 响应体是流（`ResponseBody`），但它的读语义在内存体与真实连接上完全一致，Mock 因此能代表网络侧的流式行为；
- 使用方也能替换传输层（自定义实现只需一个方法）。

### 2. 配置是值语义 + `Option` 字段

`Config` 的所有字段都是 `Option[T]`，`None` = 「未提供」。这是复刻 axios `mergeConfig` 的前提：axios 用 JS 的 `undefined` 表达同一件事，而 `null`/`undefined` 与「显式给了个值」必须能区分开，否则会丢掉「回退到默认值」这条规则。

配套约定：所有变更方法（`with_*`、`Headers::set`、`Client::create`）都**返回新实例**，不就地修改。`Config` 会被多个实例共享（`Client::create` 派生时），一旦有就地修改就会出现「改 A 影响 B」的幽灵 bug。

### 3. 类型在定义它的包里再导出

MoonBit 的 import 是包级的：`Config` 的字段类型 `Headers` 定义在另一个包里，使用者若要用 `Config` 就得 import 两个包。为此确立约定：

> 凡是出现在公开签名里的类型，都在定义它的包里用 `pub using` 再导出一次；根包（`src/facade.mbt`）也再导出一份。

所以日常使用只需要 `@moonhttp` 一个 import。

## 怎么扩展

### 新增一个配置字段（最常见）

1. `src/config/config.mbt` 的 `Config` 加字段（`Option[T]`），文档注释里写明它在哪一档合并策略下；
2. `src/config/config.mbt` 加 `with_*` 构建器（若使用者需要设置它）；
3. `src/config/render.mbt` 的 `Config::to_string` 里加一行渲染（可选，但有助于排查）；
4. `src/merge/merge.mbt` 的 `merge_config` 里**显式**选择一档策略调用，并在注释里说明为什么是这一档；
5. 若它参与请求构造，接到 `src/pipeline.mbt` 的 `build_prepared_request` / `build_response`；
6. 补测试：`src/merge/merge_test.mbt` 测合并语义，`src/*_test.mbt` 测端到端效果；
7. 更新 `docs/02-config-merge.md` 的字段归属表。

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
  { status: 200, status_text: "OK", headers: Headers::new(), body: b"{}" }
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
| `pub(all) struct` 里允许个别字段标 `priv` | `StreamResponse` 就靠这条：状态行与响应头公开，响应体流私有，读取必须走本类型的方法，错误才能统一成 `HttpError` |
| `errdefer` 在 async 函数里同样有效，适合「失败就关连接」这类清理 | 传输层用它保证建连之后的任何失败都关闭连接；比 `try ... catch { cleanup; raise }` 更短，也不会触发 `fragile_catch_all` 告警 |
