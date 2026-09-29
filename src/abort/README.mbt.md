# abort —— 取消原语（AbortController / AbortSignal）

`AbortController` 与 `AbortSignal`：控制器用来发起取消，信号随请求走、只负责观察。

```toml
import {
  "q2316367743/moonhttp/abort",
}
```

## 语义

- **发起方与观察方分开**：`AbortController` 留给需要叫停的一方（UI 的停止按钮、看门狗），随请求走的是 `controller.signal()` 给出的 `AbortSignal`。
- **一次性**：取消之后永远是取消状态，不能复用；一次请求一个信号就每次 `AbortController::new()`。
- **可共享**：同一个信号可以挂到任意多个请求上，`abort` 一次全部生效。
- **幂等**：重复 `abort` 只生效第一次，第二次连理由都不会改。
- **已取消的信号可以直接传**：拿它发请求会立刻以取消失败收场，理由就是 `abort` 时给的那个。
- 从三个入口看到的取消失败都是 `HttpError`：`error.is_cancelled()` 为真，`code` 是 `Cancelled`（`ERR_CANCELED`）。

完整语义与边界见 [docs/12-cancellation.md](../docs/12-cancellation.md)。

## API

| 方法 | 说明 |
|---|---|
| `AbortController::new()` | 造一个尚未取消的控制器 |
| `AbortController::signal()` | 取出它的信号 |
| `AbortController::abort(reason?)` | 发起取消；同步、不抛错、幂等、一次性 |
| `AbortSignal::abort(reason?)` | 静态构造：出生就已取消的信号 |
| `AbortSignal::aborted()` | 是否已取消 |
| `AbortSignal::reason()` | 取消理由，`String?`（默认文案在错误层） |
| `AbortSignal::throw_if_aborted()` | 已取消就抛 `AbortError` |

`attach` / `detach` 是库内部的中断登记接口，写业务代码用不到。

## 用法

```moonbit nocheck
let controller = @abort.AbortController::new()

// 信号按请求传：它是入口的 signal? 参数，不在 Config 上
client.request(Config::new("/reports/big.csv"), signal=controller.signal())

// 另一条协程里（UI 的停止按钮、看门狗、超时兜底）：
controller.abort(reason="用户点了停止")
```

```moonbit nocheck
// 已经不该再发的请求：把「已取消」变成一个可以直接传的值

///|
let signal = @abort.AbortSignal::abort(reason="上游已整体超时")
```
