# headers —— 大小写不敏感的 HTTP 头集合

大小写不敏感的 HTTP 头集合：字符串规范化与集合运算，不碰网络。

```toml
import {
  "q2316367743/moonhttp/headers",
}
```

## 语义

- **头名大小写不敏感**（HTTP 规定只在 ASCII 范围内折叠）：`get("Content-Type")` 与 `get("content-type")` 命中同一条；输出沿用该头名首次写入时的拼写。
- **所有变更方法都返回新实例**，不做就地修改：同一份头可以安全共享，改一处不会连带改另一处。
- **一个头名只有一个字符串值**：不展开多值头。
- 补默认头一律走 `set_if_absent`：你自己设过的头不会被默认值覆盖。

## API

| 方法 | 说明 |
|---|---|
| `Headers::new()` | 空集合 |
| `Headers::from_pairs([("A", "1")])` | 从数组构造 |
| `Headers::get(name)` | 取值，`String?` |
| `Headers::has(name)` | 是否存在 |
| `Headers::set(name, value)` | 写入 / 覆盖，返回新实例 |
| `Headers::set_if_absent(name, value)` | 只在缺失时写入（补默认头用它） |
| `Headers::remove(name)` | 删除，返回新实例 |
| `Headers::merge(other)` | 合并，`other` 的同名头覆盖本实例 |
| `Headers::entries()` | 全部 `(名, 值)`，顺序即写入顺序 |
| `Headers::length()` / `is_empty()` | 数量判断 |
| `Headers::to_string()` / `equal` / `not_equal` / `repr` | 输出与比较（`Show` / `Eq` / `Debug`） |

## 用法

```moonbit nocheck
let headers = @headers.Headers::new()
  .set("Content-Type", "application/json")
  .set_if_absent("Accept", "application/json, text/plain, */*")

headers.get("content-type") // Some("application/json")
headers.has("ACCEPT") // true
```
