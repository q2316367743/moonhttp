# sse —— SSE 事件解析

纯逻辑包：吃字节、吐事件，不碰网络、不碰 async。解析规则按 WHATWG EventSource 规范实现，用同步测试逐条钉死。任何字节来源（HTTP 响应体、文件、WebSocket）都能复用同一个解析器。

```toml
import {
  "q2316367743/moonhttp/sse",
}
```

## 为什么不能用 `read_until("\n\n")` 切事件

规范允许行尾是 CRLF / LF / CR 三种，而 CRLF 流上事件边界的字节是 `0D 0A 0D 0A`——里面没有连续两个 `0A`，按 `"\n\n"` 找分隔符永远匹配不到，会一直累积到连接关闭。所以这里按字节扫描，自己识别三种行尾。

## `SseEvent`

| 字段 | 说明 |
|---|---|
| `event` | 事件类型，来自 `event:` 字段；流里没给过就是规范默认的 `"message"` |
| `data` | 事件数据，来自 `data:` 字段；同一事件的多条 `data:` 行用 `\n` 连接 |
| `id` | 最近一次 `id:` 的值；`None` 表示流里还没出现过 |
| `retry` | 最近一次 `retry:` 的毫秒值；`None` 表示流里还没出现过 |

`id` 与 `retry` 是**跨事件持久的解析器状态**（对齐 EventSource 的内部状态）：一旦出现过，就跟着后面每个事件一起交出来。断线重连要用这两个值，本包不自动重连，把它们留给调用方。

## `SseParser`

| 方法 | 说明 |
|---|---|
| `SseParser::new()` | 干净状态：没有事件，也没有 ID / 重连间隔 |
| `push(chunk)` | 喂一块字节；完整的事件进内部队列 |
| `next()` | 取一个已解析完的事件，没有就 `None`——**`None` 不代表流结束**，可能只是数据还没到齐 |
| `finish()` | 告诉解析器「流到此结束」（读到 EOF 时调用一次），处理末尾那个卡住的裸 CR；未以空行收尾的半行按规范丢弃。重复调用安全 |

## 用法

```moonbit nocheck
let parser = @sse.SseParser::new()
parser.push(chunk1)
parser.push(chunk2) // 一块含 0 个、1 个或多个事件都行；事件也可能横跨多块
while parser.next() is Some(event) {
  println(event.event + ": " + event.data)
}
parser.finish()
```

## 几个边界

- **任意切分安全**：行尾、字段、甚至一个 UTF-8 字符被切在中间都没问题。缓冲区末尾的裸 CR 会留到下一块再判定——立刻消费就会把 CRLF 当成两次换行，凭空多切出一个空事件。
- 三种行尾都认：CRLF / LF / CR。流开头的 UTF-8 BOM 会被丢掉。
- `data` 缓冲为空的块**不发事件**（只有 `id:` / `retry:` 或注释的块属于这种）；`data:` 写了空值是「data 为空串的事件」，照发。
- `retry:` 的值必须全是 ASCII 数字才生效，其它情况整体忽略、不改动已生效的值。

完整规则与实现取舍见
[`docs/06-sse.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/06-sse.md)。
