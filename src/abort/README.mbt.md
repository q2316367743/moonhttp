# abort —— 取消原语（AbortController / AbortSignal）

纯逻辑包：只有状态，没有底层机制，不碰网络、不碰 async。对应 JS 平台原生的
`AbortController` / `AbortSignal`，也是本项目替代 axios 那套 `CancelToken` 的形态。

真正打断一次请求（挂起中的建连、读写）的机制在 `transport` 包（那里才有 `@async`）；
取消的语义、覆盖范围与注意事项见 [docs/12-cancellation.md](../docs/12-cancellation.md)。

```toml
import {
  "q2316367743/moonhttp/abort",
}
```

## 语义

- **发起方与观察方分开**：`AbortController` 留给需要叫停的一方（UI 的停止按钮、看门狗），
  随请求走的是 `controller.signal()` 给出的 `AbortSignal`。拿到信号的一方只能观察，
  「误调用取消」在类型上就写不出来。
- **一次性**：取消之后永远是取消状态，不能复用；一次请求一个信号就每次 `AbortController::new()`。
- **可共享**：同一个信号可以挂到任意多个请求上，`abort` 一次全部生效；
  信号与控制器共享状态（复制信号不复制状态）。
- **幂等**：重复 `abort` 只生效第一次，第二次连理由都不会改。
- **已取消的信号上登记既不触发、也不保留**（与 JS 的 `addEventListener` 一致）。
  所以「取消晚一步」的兜底是**登记点自己先查 `aborted()`**，不是登记的副作用。
- **`AbortError` 不跨库边界**：`throw_if_aborted()` 为「每段开头先查一眼」而存在，
  它抛的 `AbortError` 只在 abort 包与根包之间流转；根包在管线入口把它归一成统一的
  `HttpError`（`is_cancelled()` / `ERR_CANCELED`），使用者只会看到一套错误体系。

## API

| 方法 | 说明 |
|---|---|
| `AbortController::new()` | 造一个尚未取消的控制器 |
| `AbortController::signal()` | 取出它的信号（与控制器共享状态） |
| `AbortController::abort(reason?)` | 发起取消；同步、不抛错、幂等、一次性 |
| `AbortSignal::abort(reason?)` | 静态构造：出生就已取消的信号（对应 `AbortSignal.abort`） |
| `AbortSignal::aborted()` | 是否已取消（对应 `signal.aborted`） |
| `AbortSignal::reason()` | 取消理由，`String?`（对应 `signal.reason`；默认文案在错误层） |
| `AbortSignal::throw_if_aborted()` | 已取消就抛 `AbortError`（对应 `signal.throwIfAborted()`） |
| `AbortSignal::attach(handle)` | **内部机制**：登记「取消时要做什么」，返回注销票号 |
| `AbortSignal::detach(ticket)` | **内部机制**：注销登记；越界票号忽略 |

## 用法

```moonbit nocheck
let controller = @abort.AbortController::new()

// 信号按请求传（它不属于配置，见 docs/12-cancellation.md）：
client.request(Config::new("/reports/big.csv"), signal=controller.signal())

// 另一条协程里（UI 的停止按钮、看门狗、超时兜底）：
controller.abort(reason="用户点了停止")
```

```moonbit nocheck
// 已经不该再发的请求：把「已取消」变成一个可以直接传的值

///|
let signal = @abort.AbortSignal::abort(reason="上游已整体超时")
```
