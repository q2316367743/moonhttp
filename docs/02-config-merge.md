# 02 配置合并契约

本项目的重点功能。契约目标是**与 axios `lib/core/mergeConfig.js` 行为一致**，包括那些看起来「反直觉但确实如此」的规则。

## 关键文件

| 文件 | 职责 |
|---|---|
| `src/config/merge.mbt` | 四种合并策略、`merge_config`、`flatten_headers` |
| `src/config/json_merge.mbt` | `params` 用的 JSON 深合并 |
| `src/config/merge_test.mbt` | 逐条钉住合并语义的黑盒测试 |
| `src/config/merge_wbtest.mbt` | 直接测四个策略函数本身的白盒测试（含只有包内造得出的部分凭据配置） |
| `src/config/config.mbt` | `Config` 的字段定义与 `with_*` 构建器 |
| `src/config/types.mbt` | `Auth` / `ResponseEncoding` 等小值类型 |
| `src/config/default.mbt` | 内置默认值 `defaults()`（对应 axios 的 `lib/defaults/index.js`） |

### 为什么合并逻辑在 `config` 包里（而不是独立的 `merge` 包）

它**曾经**是独立的 `merge` 包。`Config.data` 改成私有字段之后，这一层站不住了：

- 构造一份合并结果必须写 `Config` 的每个字段，而**包外既不能写记录字面量、
  也不能用记录展开**（编译器报 `Cannot use struct update syntax on struct Config
  because it has private fields`），所以 `merge_config` 只能与 `Config` 同包；
- 顺带得到一个更强的保证：往 `Config` 加字段却忘了在 `merge_config` 里选一档策略，
  **是编译错误**，而不是静默地漏合并（`Config::default()` / 记录字面量必须列全字段）。

`config` 因此同时是「配置的形状」与「配置的合并契约」，两层都是纯逻辑、都能用同步测试覆盖，
`merge` 这个包名消失只是名字上的变化。唯一的连带影响：`flatten_headers` 也搬来了 `config`，
`util` 的调用点从 `@merge.flatten_headers` 改成 `@config.flatten_headers`。

## 为什么不用「表驱动」

axios 维护一张 `字段 → 合并函数` 的表，然后遍历所有键。MoonBit 没有运行时反射，无法遍历结构体字段，所以改为**逐字段显式调用对应策略**：

```moonbit
pub fn merge_config(base : Config, request : Config) -> Config {
  {
    url: value_from_request(base.url, request.url),       // 只取请求级
    timeout: prefer_request(base.timeout, request.timeout), // 请求优先，否则默认
    params: merge_json_option(base.params, request.params), // 深合并
    validate_status: request_overrides(...),               // 存在即生效
    ...
  }
}
```

好处是每个字段属于哪一档在源码里一眼可见，不需要再去查表；而且**漏字段是编译错误**——
记录字面量必须列全 `Config` 的所有字段（这条在 `data` 变成私有字段后更强了：
跨包连字面量都写不出来，见下文「为什么合并逻辑在 `config` 包里」）。

## 四种策略

| 策略函数 | axios 原名 | 语义 |
|---|---|---|
| `value_from_request` | `valueFromConfig2` | **只取请求级**；请求没提供就是 `None`，不回退 |
| `prefer_request` | `defaultToConfig2` | 请求级优先，缺省回退默认值 |
| `merge_*` 系列 | `mergeDeepProperties` | 复合值深合并；标量等价于 `prefer_request` |
| `request_overrides` | `mergeDirectKeys` | 请求级存在即生效（本项目的 `Option` 语义下与 `prefer_request` 同形，保留独立命名以标明语义差异） |

`merge_*` 系列各管一类复合值：

- `merge_headers`：`Headers` 大小写不敏感合并（请求级同名头覆盖，默认值独有的头保留）；
- `merge_auth`：`Auth` 逐字段合并（默认值给 `username`、请求给 `password`，两者都在）；
- `merge_proxy`：`Proxy` 逐字段合并（默认值给代理地址、请求级给凭据，两者都在）；内层 `auth` 递归交回 `merge_auth`；
- `merge_json_option` / `merge_json`：JSON 对象逐键递归合并；
- `merge_method_headers`：按方法分桶合并（请求级只改一个方法不能清掉别的桶）。

## 字段归属表

| 字段 | 策略 | 行为 |
|---|---|---|
| `url` | 只取请求级 | 默认值里的 url 永远不生效，也不回退 |
| `http_method` | 只取请求级 | 见下方「方法缺省」 |
| `data` | 只取请求级 | 默认值里的 body 同样不生效。字段是私有的，设置只能经 `with_data_from_str` / `with_data_from_json` / `with_data_from_form` / `with_data_from_urlencoded`（见 `07-request-body.md`） |
| `base_url` | 请求优先/否则默认 | |
| `timeout` | 请求优先/否则默认 | |
| `max_redirects` | 请求优先/否则默认 | axios 没把它登记进 `mergeConfig` 的表，落到默认的深合并策略，标量上等价于请求优先。内置默认值是 5，请求级的 `0`（不跟随）必须能覆盖掉它，见 `08-redirects.md` |
| `response_encoding` | 请求优先/否则默认 | 内置默认值是 `Utf8`（axios 的 `responseEncoding: 'utf8'`） |
| `params_serializer` | 请求优先/否则默认 | 自定义 query 序列化器（axios 的 `paramsSerializer`，登记为 `defaultToConfig2`）。请求级提供即**整体替换**实例默认值，不是深合并——函数没法「合并」；字段说明见 `03-request-pipeline.md` |
| `allow_absolute_urls` | 深合并（标量） | 等价于请求优先/否则默认 |
| `params` | 深合并 | 逐键递归；数组**整体替换** |
| `auth` | 深合并 | 逐字段 |
| `proxy` | 深合并 | 逐字段（内层 `auth` 同样逐字段）。「给了 proxy 却没给 host」是配置错误而不是「没配代理」，见 `09-proxy.md` |
| `headers` | 深合并（大小写不敏感） | |
| `common_headers` | 深合并 | |
| `method_headers` | 深合并（按方法分桶） | |
| `validate_status` | 存在即生效 | 请求级提供即整体接管 |

## 两个构造器

| 写法 | 用途 |
|---|---|
| `Config::new(url)` | 构造**请求级**配置：`url` 是每次请求都必须提供的字段，把它做成构造参数，最常见的调用从 `Config::default().with_url("/users")` 缩短成 `Config::new("/users")` |
| `Config::default()` | 全空配置（所有字段 `None`），用于「只设置某几项」的场景，也是 `Config::new` 的基底 |

两者不能混用场景：`Config::new(url)` 设的是**本次请求的目标地址**（`Config.url`）。给实例设置基础地址必须用 `Config::default().with_base_url(...)`——`url` 在合并时走「只取请求级」策略，放进实例默认值里永远不会生效（这正是 `valueFromRequest` 那一档存在的意义）。

## 需要注意的语义细节

### `None` = `undefined`，永远回退而不是覆盖

axios 里 `config2` 的 `undefined` 表示「没提供」，会落到 `config1`。本项目用 `None` 表达同一件事，所以**没有办法通过「传空」来清掉一个默认值**。唯一的例外是 `validate_status`：axios 的 `mergeDirectKeys` 连显式的 `null` 都算「存在」，用来关掉校验；本项目对应的写法是传一个恒真函数。

### 方法缺省是两段回退

`http_method` 走「只取请求级」，所以合并结果里通常没有方法。axios 在 `_request` 里单独做了一次回退：

```js
config.method = (config.method || this.defaults.method || 'get').toLowerCase();
```

本项目在 `Client::request` 里复刻为「合并结果 → 实例默认值 → `Method::Get`」。

### 数组是替换而不是拼接

axios 的 `utils.merge` 只对普通对象递归，数组走 `val.slice()` 直接替换。所以默认值 `params: {"tags": ["a"]}` + 请求 `params: {"tags": ["b"]}` 的结果是 `["b"]`。这条由 `src/config/merge_test.mbt` 的 "params arrays are replaced not concatenated" 用例钉住。

### 头是三层的，合并与拍平是两步

axios 的默认值里 `headers` 是 `{common: {...}, get: {...}, post: {...}}` 结构，而请求级 `headers` 是平铺的。本项目把它拆成三个字段：

- `common_headers`：`common` 层；
- `method_headers`：`Map[Method, Headers]`，按方法层；
- `headers`：请求级平铺层。

合并阶段各层分别深合并；拍平阶段由 `flatten_headers` 按 `common` < 按方法 < 请求级平铺 逐层 `merge`（后者覆盖前者）。两个阶段分开是必要的：请求级配置可能同时设置多层，而拍平要等到方法确定之后才能做。

### 合并结果不与输入共享可变状态

`Headers` 的所有变更方法都返回新实例，`method_headers`（一个 `Map`）在合并与 `with_method_header` 里都先 `copy()` 再改，因此 `merge_config` 的结果可以安全地独立修改，不会反噬输入。`src/*_test.mbt` 的 "merge result does not alias the inputs" 用例守着这条。
