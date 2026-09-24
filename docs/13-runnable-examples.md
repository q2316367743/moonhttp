# 可运行示例（`src/main/`）

面向维护者：这组示例怎么组织、为什么这么选靶子、加一个新示例要做什么，以及跑出来的两个已知问题。

使用者视角的索引（每个示例演示什么、怎么跑、前置条件）在 [`src/main/README.md`](../src/main/README.md)。

## 为什么是「可运行程序」而不是测试

`moon test` 里的用例回答「功能对不对」（断言、Mock、确定性的靶子）；`src/main/` 下的示例回答「真链路上是什么样」：

- 它们走真实的 socket、TLS、代理与真实站点，输出是给人看的**观察结果**而不是断言；
- 不用 `test` 块，所以不进 `moon test`，不受 CI 的运行时间与网络隔离约束；
- 每个方向一个 `pkgtype(kind: "executable")` 的包，`moon run src/main/<方向>` 单独跑，互不干扰。

两者互补：测试证明契约，示例暴露真实环境的脾气（下面「已知问题」的两条就是这样发现的）。

## 目录与靶子

七个方向各一个包，另有原来的快速上手示例（`src/main/main.mbt`，不动它——根 `README.mbt.md` 引用着它）。

| 包 | 靶子 | 为什么是这个靶子 |
|---|---|---|
| `basics` | 自起本机 server + 华为云镜像 | 状态码 / 头 / 超时这些行为必须确定，故用本机；真实站点只用来证明「真网络也走得通」 |
| `methods` | 自起本机 echo server | 方法、请求体形态、响应内容形态都要「服务端视角的证据」，echo server 一次全给 |
| `proxy` | 本机代理（`http://127.0.0.1:7890`）+ 真实站点 | 代理是环境相关的东西，只能打真实代理；出口 IP 对比是「流量真的从代理出去」的唯一硬证据 |
| `progress` | 自起本机 server（快读 / 慢读）+ 华为云大文件 | 分块节奏要可控（本机）；「5% 取消」要在真实慢速大文件上验证（公网） |
| `redirect` | 自起本机 server + qq.com / 清华镜像 | 301/302/303/307/308 全家族、成环、跨 host 只能自造；真实站点各留一条 |
| `interceptors` | 自起本机 echo server | 拦截器改的头有没有真的发出去，只有服务端回显能证明 |
| `sse` | 本机 OpenAI 兼容服务（`127.0.0.1:8910/v1`） | SSE 需要一个真的会「边生成边吐」的服务，本机这个最方便 |

约定：

- 示例内部起的 server 一律用 `run_forever(allow_failure=true)`——某条用例取消 / 超时会让那一次 handler 的写动作失败，不该把整个 server 带走；
- 需要外网的用例一律 `try` / `catch`，失败只打印错误分类；
- 打印要节流：真实下载按 64 KiB 回调，逐次打印会淹没控制台（示例按整数百分比或每 256 KiB 打印一行）。

## 加一个新示例（清单）

1. 建目录 `src/main/<方向>/`，写 `moon.pkg`：`pkgtype(kind: "executable")` + 只 import 用到的包（`moonbitlang/async` 是 async main 必需；起本机 server 才要 `async/http` + `async/socket`）。
2. 写 `main.mbt`：`async fn main`，≤300 行（RL-04，`src/main` 不在根包例外里）；文件头用 `///|` 文档注释写清「演示什么、靶子是谁、怎么跑」。
3. 跑 `moon info`（生成空的 `pkg.generated.mbti`，**要提交**，否则 CI 的接口门禁会挂）与 `moon fmt`。
4. 更新 [`src/main/README.md`](../src/main/README.md) 的索引表与本文的靶子表。
5. 别写 `test` 块；`.moonignore` 已经排除了整个 `src/main/`，不用再管发布。

## 已知问题（示例跑出来的）

两条都只在 **HTTPS** 上出现（明文 HTTP 正常），都可以用示例里的写法绕过或观察，但根因在库 / 底层运行时，尚未修。

### 1. 从进度回调里取消，HTTPS 下载会让原生进程崩溃（SIGSEGV）

现象：把取消写在 `on_download_progress` 回调里，目标是 HTTPS 大文件时进程直接挂掉（退出码 139），连调用方的 `catch` 都跑不到。

对照（同一段代码，逐项排除）：

| 靶子 | 从哪里发起取消 | 结果 |
|---|---|---|
| 本机明文 HTTP、64 MiB | 进度回调 | 正常，报 `ERR_CANCELED` |
| 本机明文 HTTP、64 MiB | 另一条协程 | 正常，报 `ERR_CANCELED` |
| HTTPS、109 MiB | 进度回调 | **崩溃（SIGSEGV）** |
| HTTPS、109 MiB | 另一条协程 | 正常，报 `ERR_CANCELED` |

机理（据 `src/transport/cancel.mbt` 与 moonbitlang/async 的取消语义推断）：`token.attach` 里登记的是 `task.cancel()`，而进度回调跑在**那个被取消的子任务内部**；此时取消信号只能在「本任务的下一个挂起点」投递（协程级取消的粘性状态），HTTPS 的读在这一路径上会走到 TLS 会话清理的坏状态。

绕法：**让取消由另一条协程发出**。`src/main/progress` 的「真实下载 + 5% 取消」就是用一个看门狗协程盯着进度数字来取消的；明文 HTTP（同文件的上传取消）照旧写在回调里，写法更像直觉。

修法方向（未做）：在 `with_cancel_scope` 的登记里避免「自己取消自己」——例如把 `task.cancel()` 交给另一个任务执行，或让读取路径的「两次读取之间查 token」承担同任务内的取消。

### 2. HTTPS 上取消的错误分类会抖成 `ERR_NETWORK`

现象：取消 HTTPS 下载时，有时拿到 `ERR_CANCELED`（正确），有时拿到 `ERR_NETWORK` + `OSError("@socket.Tcp::read(): Bad file descriptor")`。取消本身是生效的（进度停住、错误里带着半截响应）。

机理：取消链路上「关闭连接」（`ResponseBody::open` 时登记）排在「中断子任务」（`read_or_fail` 时登记）**前面**，所以在线的那次读可能先撞上「描述符已关闭」；`src/transport/read_or_fail` 的兜底把非超时错误一律归成 `Network`，于是分类丢了。

绕法：示例照实打印（`src/main/progress` 在分类不是 `ERR_CANCELED` 时会多打一行说明）。

修法方向（未做）：`read_or_fail` 的 catch-all 里先看一眼 token——`token.is_cancelled()` 成立就报 `Cancelled`，否则才报 `Network`（两行改动），并补一条 HTTPS 侧的用例。
