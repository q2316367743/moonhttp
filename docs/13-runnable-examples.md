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

九个方向各一个包，另有原来的快速上手示例（`src/main/main.mbt`，不动它——根 `README.mbt.md` 引用着它）。

靶子有两种来路：早期六个包**自起**本机 server；`transport` 与 `cookies` 打 [`test/`](../test/README.md) 里的 **Python 共享靶子**（`test/server.py`，`bash test/run.sh` 一条命令起靶子跑完全部）——官方 `@http.Server` 的 `RequestMethod` 是封闭枚举收不了 `PROPFIND`，gzip / HTTP/1.0 / 原始分帧在 MoonBit 侧造起来也别扭，这些语义交给成熟运行时摆正，示例包本身只发请求。

| 包 | 靶子 | 为什么是这个靶子 |
|---|---|---|
| `transport` | `test/` 的 Python 共享靶子 | 自研栈的新语义（gzip 三态 / 大响应体 / UA / WebDAV 方法 / HTTP/1.0）需要在线上精确控帧与自定义方法回显，Python 全都做得到（见 docs/18） |
| `cookies` | `test/` 的 Python 共享靶子 | Set-Cookie 的种 / 刷 / 删 / Path 限定全在查询参数里可配，一条路由覆盖全部场景（见 docs/19） |
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

1. 建目录 `src/main/<方向>/`，写 `moon.pkg`：`pkgtype(kind: "executable")` + 只 import 用到的包（`moonbitlang/async` 是 async main 必需；自起本机 server 才要 `async/http` + `async/socket`，打共享靶子则一个都不用加）。
2. 先想清楚靶子：线上语义复杂（自定义方法、控帧、gzip、cookie 场景）就往 `test/server.py` 加一条路由；只是确定性的 echo / 慢响应，自起本机 server 也行。
3. 写 `main.mbt`：`async fn main`，≤300 行（RL-04，`src/main` 不在根包例外里）；文件头用 `///|` 文档注释写清「演示什么、靶子是谁、怎么跑」。
4. 跑 `moon info`（生成空的 `pkg.generated.mbti`，**要提交**，否则 CI 的接口门禁会挂）与 `moon fmt`。
5. 更新 [`src/main/README.md`](../src/main/README.md) 的索引表与本文的靶子表。
6. 别写 `test` 块；`.moonignore` 已经排除了整个 `src/main/`，不用再管发布。

## 示例跑出来的问题

下面两条都只在 **HTTPS** 上出现（明文 HTTP 正常）：第 1 条已于 2026-11-09 修复并有回归用例；
第 2 条的竞争机理还在（自研栈上一次实测未复现）。

### 1. 从进度回调里取消，HTTPS 下载曾让原生进程崩溃（SIGSEGV）——已修复（2026-11-09）

现象（修复前）：把取消写在 `on_download_progress` 回调里，目标是 HTTPS 大文件时进程直接挂掉
（退出码 139），连调用方的 `catch` 都跑不到。

对照（同一段代码，逐项排除）：

| 靶子 | 从哪里发起取消 | 结果 |
|---|---|---|
| 本机明文 HTTP、64 MiB | 进度回调 | 正常，报 `ERR_CANCELED` |
| 本机明文 HTTP、64 MiB | 另一条协程 | 正常，报 `ERR_CANCELED` |
| HTTPS、109 MiB | 进度回调 | **崩溃（SIGSEGV）** |
| HTTPS、109 MiB | 另一条协程 | 正常，报 `ERR_CANCELED` |

根因（2026-11-09 用 lldb 复现，栈顶是 `SSL_read`，指针指向已释放的 `SSL`）：取消处理里
`ResponseBody` 的「取消即关闭」登记会**同步关闭连接**——TLS 的 `SSL` 对象随之释放；而读全量
的循环（`drain_into`）在进度回调返回后继续下一轮 `read()`，于是在已释放的 TLS 上做
`SSL_read`。协程级取消没来得及挡住这一步：`timeout` 在场时真正的读跑在 `with_timeout` 再
下一层的子协程里，`task.cancel()` 先落在外层子任务上，这一层要等下一个挂起点才能看到取消
——下一轮读往往就是那个挂起点。

修法（已落地）：

- `src/transport/stream_all.mbt` 的 `drain_into` **每报完一次进度查一次 `signal.aborted()`**，
  已取消就在下一轮读之前抛 `TransportError::Cancelled`；`read_or_fail` 把这个错误原样透传
  （不再被兜底成 `Network`）。
- 回归用例 `src/transport/stream_cancel_progress_test.mbt` 的
  `cancelling in the download progress callback stops before the next read` 用一个「关闭后
  再读就 abort」的假 reader 在纯内存里钉住时序，不依赖 TLS 与网络。
- `src/main/progress` 的「真实下载 + 5% 取消」改回**在进度回调里直接取消**（原来为绕开崩溃
  用的看门狗协程已删除）；明文 HTTP 的上传取消写法不变。

细节见 `docs/12-cancellation.md` 的「与进度回调」一节。

### 2. HTTPS 上取消的错误分类会抖成 `ERR_NETWORK`

现象：取消 HTTPS 下载时，有时拿到 `ERR_CANCELED`（正确），有时拿到 `ERR_NETWORK` + `OSError("@socket.Tcp::read(): Bad file descriptor")`。取消本身是生效的（进度停住、错误里带着半截响应）。

机理：取消链路上「关闭连接」（`ResponseBody::open_wire` 时登记）排在「中断子任务」（`read_or_fail` 时登记）**前面**，所以在线的那次读可能先撞上「描述符已关闭」；`src/transport/stream.mbt` 的 `read_or_fail` 兜底把非超时错误一律归成 `Network`，于是分类丢了。（本条是旧栈时期观察到的；2026-10-01 在自研栈上实测一次未复现——`progress` 示例的 HTTPS 5% 取消干净落在 `ERR_CANCELED`、半截 5.4 MiB 保住了，但「关连接与中断谁先到」的竞争机理还在，换网络换负载多跑几次才能下结论。）

绕法：示例照实打印（`src/main/progress` 在分类不是 `ERR_CANCELED` 时会多打一行说明）。

修法方向（未做）：`read_or_fail` 的 catch-all 里先看一眼信号——`signal.aborted()` 成立就报 `Cancelled`，否则才报 `Network`（两行改动），并补一条 HTTPS 侧的用例。
