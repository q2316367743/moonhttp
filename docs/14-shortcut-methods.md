# 14 快捷方法（`get` / `post` / `put` / `delete` / `head` / `options` / `patch`）

七个 HTTP 动词各一个方法，对应 axios 的 `axios.get(url, config)` 那一组。实现只有两件事——补上 `url` 与动词，然后转调 `Client::request`。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/shortcuts.mbt` | 七个方法 + 共用的私有辅助函数 `Client::send_verb`（本文件唯一的逻辑） |
| `src/client.mbt` | 被转调的 `Client::request`：合并 → 定方法 → 拦截器 → 发送 → 读全量 → 校验（见 `03-request-pipeline.md`） |
| `src/shortcut_test.mbt` | 契约的用例：动词、优先级、实例默认值、请求体、错误路径 |
| `src/config/config.mbt` | `Config::new(url)` / `with_url` / `with_method`：`send_verb` 只调这三个构建器 |

## 签名

七个方法签名完全一致，只有动词不同：

```moonbit nocheck
pub async fn Client::get(self : Client, url : String, config? : Config) -> Response raise HttpError
pub async fn Client::post(self : Client, url : String, config? : Config) -> Response raise HttpError
pub async fn Client::put(self : Client, url : String, config? : Config) -> Response raise HttpError
pub async fn Client::delete(self : Client, url : String, config? : Config) -> Response raise HttpError
pub async fn Client::patch(self : Client, url : String, config? : Config) -> Response raise HttpError
pub async fn Client::head(self : Client, url : String, config? : Config) -> Response raise HttpError
pub async fn Client::options(self : Client, url : String, config? : Config) -> Response raise HttpError
```

## 三条契约

1. **`url` 位置参数永远赢**。传入的 `config` 自带 `url` 时也以位置参数为准——`send_verb` 无条件 `with_url(url)`。这是 axios 的语义（`axios.get(url, config)` 也忽略 `config.url`），也让「裸配置 + 短地址」的写法成立：`api.get("/users", config=Config::default().with_params(...))`。
2. **动词永远赢**。`config` 里的 `with_method(...)`、乃至实例默认方法（`client.create(Config::default().with_method(...))`）都盖不掉「`api.get(...)` 一定是 GET」。理由：方法名就是调用方最明确的意图，让它被更远处的配置改写会得到「名字与行为不符」的代码。反过来说，不走快捷方法的老写法（`api.request(Config::default())`）仍然照旧回退到实例默认方法。
3. **不给 `config` 时**按 `Config::new(url)` 起步，等价于「只有 url 的一份请求级配置」。最省事的调用因此是 `api.delete("/users/1")`。

除此之外**没有任何新语义**：实例默认值（`base_url` / 公共头 / `timeout` / `max_redirects`）、三层头拍平、`params` / `params_serializer`、两段拦截器、自动重定向、进度回调、取消、状态码校验全部还是 `Client::request` 那一套。这就是「薄封装」的判据——**改 `request` 的语义时不需要同步 `shortcuts.mbt`**，反之实现里出现第二份管线逻辑就是走错了方向。

## 用法

```moonbit nocheck
let api = @moonhttp.create(
  @moonhttp.Config::default().with_base_url("https://api.example.com"),
)

// 只需 url
let repos = api.get("/repos")

// 实例默认值 + 本次请求的配置：地址拼接、query、超时都在
let page = api.get("/repos", config=@moonhttp.Config::default().with_params({
  "page": 1,
}))

// 请求体走 config：四种形态一视同仁，且「补 Content-Type」的规则与 request 相同
let created = api.post("/users", config=@moonhttp.Config::default().with_data_from_json({
  "name": "moon",
}))
```

**请求体为什么不进参数列表**：本项目的请求体有四种形态（`str` / `json` / `form` / `urlencoded`，见 `07-request-body.md`），任何一个参数类型都只能覆盖其中一种。挑 `Json` 当参数会让人以为「POST 只能发 JSON」，表单与纯文本被迫绕回 `config`；四种都支持则要在 `Config` 之外再造一个公开的 body 类型，与既有的四个 `with_data_from_*` 构建器重复。统一的 `config` 入口反而最短：形态由构建器决定，补 `Content-Type` 的规则只有一处（`07-request-body.md`）。

## 为什么是七个独立的函数，而不是重载

MoonBit 不允许同一类型上有同名方法（`The method request for type Client has been defined`），所以「用更短的调用点表达同一件事」只能靠**不同的函数名**。同一条限制造就了 `Config::new(url)`，也正是这里七个动词各自成名的原因——`Client::request` 的位置参数只能有一个，加不了「url 优先」的重载。详见 `01-architecture.md` 的语言注意事项表。

## 为什么没有 `stream` / `sse` 的快捷方法

那两个入口的返回类型不同（`StreamResponse` / `SseStream`），做成快捷方法只能凑出 `get_stream` / `get_sse` 这类名字，把「七个动词 × 三个入口」的组合展开成 21 个函数。要流式 GET 就写 `api.stream(Config::new(url))`——**入口**是轴上的一个维度，不该被塞进动词的名字里。

## 加第 8 个动词（`connect` / `trace`）

`Method` 里没有快捷方法的是 `Connect` 与 `Trace`（axios 同样只给这七个动词做了快捷方法，这两个只能走 `axios.request`）。真要用动词名当方法名，照 `src/shortcuts.mbt` 加一个转调即可：

```moonbit nocheck
pub async fn Client::trace(self : Client, url : String, config? : Config) -> Response raise HttpError {
  self.send_verb(url, @config.Method::Trace, config?)
}
```

`send_verb` 是包私有的共用出口，所以新增一个动词只有这一处调用，`url` / 动词的优先级规则不会分叉。记得同步 `README.mbt.md` 的快捷方法一节与 `docs/README.md` 的索引描述。
