# main —— 可运行示例

不是库的一部分，而是一个 `pkgtype(kind: "executable")` 的示例程序：本地手动测试用，真实发一次 HTTP 请求，演示这个客户端的基本用法。

```bash
moon run src/main   # 需要联网
```

它依次演示：

1. **创建实例**：把 `base_url`、超时与公共头写进实例默认值，后续请求只写路径；
2. **纯文本响应**：`text()` 是按 `response_encoding`（默认 UTF-8）解码出的原文，库不做任何解析；
3. **JSON 响应**：要对象就显式调 `json()`，用模式匹配取出字段；
4. **查询参数与实例派生**：`Client::create` 派生的实例继承父实例的默认值，再叠加本次配置；
5. **错误处理**：默认只把 2xx 当作成功，404 抛出 `HttpError`，错误上带着分类、配置与服务端返回的响应；
6. **拦截器**：请求侧在发出前改配置、响应侧拿到响应后观察或改写。

代码与逐段注释见同目录的 [`main.mbt`](https://github.com/q2316367743/moonhttp/blob/master/src/main/main.mbt)。

## 两个约定

- **不随模块发布**：根目录的 `.moonignore` 把这个目录排除在打包之外，`moon publish` 不会带上它（它只是本地示例，不是包内容）。
- 本包的 `pkg.generated.mbti` 是空的：示例程序不对外暴露任何 API。
