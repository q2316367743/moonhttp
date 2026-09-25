# main —— 可运行的示例

不是库的一部分，而是一组 `pkgtype(kind: "executable")` 的示例程序：本地手动测试用，**每个方向一个包、单独 `moon run`**。

它们不进 `moon test`：不用 `test` 块，而是真实发请求、把结果 `println` 出来（打本机靶子时由示例自己起 server）。整个 `src/main/` 都在根目录 `.moonignore` 里，`moon publish` 不会带上它们。

## 快速上手（`src/main`）

```bash
moon run src/main   # 需要联网
```

依次演示：创建实例、纯文本响应、JSON 响应、查询参数与实例派生、错误处理、拦截器。逐段注释见 [`main.mbt`](https://github.com/q2316367743/moonhttp/blob/master/src/main/main.mbt)。

## 七个方向的示例

| 包 | 跑法 | 覆盖什么 | 前置条件 |
|---|---|---|---|
| `basics` | `moon run src/main/basics` | 状态行与响应头、查询参数（含自定义 `paramsSerializer`）、二进制响应、`response_encoding` 的读法、204 空正文、4xx / 5xx 的错误分类、`validate_status`、超时 | 联网（真实站点打华为云镜像） |
| `methods` | `moon run src/main/methods` | 八种请求方式；请求体四形态（raw / json / urlencoded / multipart）；响应内容形态（JSON / 文本 / 二进制 / 201 / 204 / 分块 / 非法 JSON） | 无（全部打本机 echo server） |
| `proxy` | `moon run src/main/proxy` | 代理 URL 拆成 host / port、直连对照、走代理打 GitHub、出口 IP 对比、代理端口没人监听、缺 host | 本机 HTTP 代理在 `http://127.0.0.1:7890`（改文件头的 `proxy_url` 可换）+ 联网 |
| `progress` | `moon run src/main/progress` | 下载进度跑到 100%、**真实大文件下载到 5% 取消**、上传 8 MiB 跑到 100%、上传到 5% 取消 | 联网（下载的是 ~109 MiB 的 openjdk tar.gz，5% 就停） |
| `redirect` | `moon run src/main/redirect` | 默认跟随、`max_redirects(0)`、超过上限、301/302 对 POST 降级、303、307/308 保持方法与正文、成环、跨 host 丢 `Authorization`、真实站点跳转 | 联网（qq.com 的 302、清华镜像的 301） |
| `interceptors` | `moon run src/main/interceptors` | 请求拦截器补 `Authorization`、请求 LIFO / 响应 FIFO 的顺序、响应拦截器改写 JSON 与响应头、请求拦截器中止 + **请求侧**错误处理器救回（错误按来源分流）、`stream` 只走请求侧链 | 无（全部打本机 echo server） |
| `sse` | `moon run src/main/sse` | 逐事件解析 OpenAI 兼容的流式对话（思维链 / 正文 / 用量 / `[DONE]`）、流式取消 | 本机 OpenAI 兼容服务在 `http://127.0.0.1:8910/v1`（key 与模型名写在文件头常量里） |

## 三个约定

- **靶子优先放本机**：除「代理」「真实下载」「SSE」三段外，用例都在示例内部起一个本机 server 当靶子——离线可跑、结果确定；而且**服务端视角的回显**（echo server 把收到的头回吐出来）才是「头真的发出去了」这类结论的证据。为什么这么混着来、以及两个已知问题（HTTPS 上取消的错误分类与原生崩溃）见 [docs/13](../docs/13-runnable-examples.md)。
- **需要外网的用例一律包在 `try` / `catch` 里**：断网、代理没起、站点变动都只打印一行错误分类，不会 panic，也不会带崩后面的段落。
- **`pkg.generated.mbti` 都是空的**：示例程序不对外暴露任何 API（`moon info` 生成，要提交，否则 CI 的接口门禁会挂）。
