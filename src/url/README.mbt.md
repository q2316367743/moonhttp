# url —— URL 拼接与 query 序列化

纯逻辑包：只做字符串 / JSON 层面的变换，不依赖本模块的其它包，也不碰网络，可以用同步测试覆盖。

```toml
import {
  "q2316367743/moonhttp/url",
}
```

## API

| 函数 | 说明 |
|---|---|
| `build_full_path(base_url?, url?, allow_absolute?)` | 算出完整地址（还没拼 query）：绝对地址且允许直连就用 `url`，否则有 `base_url` 就拼接，都没有则原样返回；地址不可用时 `None` |
| `build_url(url, params?, serializer?)` | 把序列化后的参数追加到地址上：已有 `?` 用 `&` 续接，`#fragment` 被丢弃 |
| `combine_urls(base, relative)` | 拼接：去掉 base 末尾的 `/` 与 relative 开头的 `/`，中间补恰好一个 `/` |
| `resolve_url(base, reference)` | 把一个相对引用解析成绝对地址（RFC 3986 的解析算法，重定向的 `Location` 用它）。结果不含 fragment；只有 base 不是绝对地址时才返回 `None` |
| `serialize_params(params)` | params → query 文本（不含前导 `?`） |
| `encode_component(text)` | 编码单个 URL 组件（query 的 key 或 value） |
| `is_absolute_url(text)` | 是否是绝对地址 |
| `url_scheme(url)` | 取 scheme（小写、不含 `://`）；`mailto:x@y` 这类没有 authority 的地址返回 `None` |
| `url_authority(url)` | 取归一化后的 authority：去掉 userinfo、主机名转小写、抹掉默认端口（`http` 的 `:80`、`https` 的 `:443`） |

## 编码规则

`serialize_params` 与 `encode_component` 是同一套规则（请求体的 urlencoded 表单也复用它）：

- 保留字符集恰好是 `A-Za-z0-9-_.*`，其余按 UTF-8 **逐字节**百分号编码（`%XX`，大写）；空格写成 `+`。
- 数组 `{ "tags": ["a", "b"] }` → `tags%5B%5D=a&tags%5B%5D=b`（方括号本身也会被编码，这是真实输出，不是字面的 `tags[]=a`）。
- 嵌套对象 → `filter%5Bstatus%5D=1`；数组里套对象 → `items%5B0%5D%5Bid%5D=1`。
- JSON 的 `null` 一律跳过，既不写 `key=` 也不写 `key=null`；数字优先使用 JSON 里保存的原始字面量，避免大整数被写成科学计数法。

## 绝对地址的判定

等价于正则 `/^([a-z][a-z\d+\-.]*:)?\/\//i`，所以：

- `//cdn.example.com/x`（协议相对地址）**算**绝对地址；
- `localhost:8080/x` **不算**——冒号后面不是 `//`，它会正常和 `base_url` 拼接。

```moonbit nocheck
@url.is_absolute_url("//cdn.example.com/x") // true
@url.is_absolute_url("localhost:8080/x") // false
@url.combine_urls("https://a.com/api/", "/users") // "https://a.com/api/users"
@url.serialize_params({ "tags": ["a", "b"] }) // "tags%5B%5D=a&tags%5B%5D=b"
```

拼接与序列化的完整规则见
[`docs/03-request-pipeline.md`](https://github.com/q2316367743/moonhttp/blob/master/docs/03-request-pipeline.md)。
