# test —— 共享靶子 server

用 Python（成熟运行时，HTTP 语义齐全）起一个**所有示例共用的本机靶子**，
示例包本身只发请求、不再各自起服务器。MoonBit 的 `@http.Server` 有两个
结构性限制，决定了靶子必须放在外面：

- `RequestMethod` 是封闭枚举，收不了 `PROPFIND` 这类自定义方法；
- gzip / HTTP/1.0 / 原始分帧这些线上语义，在 MoonBit 侧造起来很别扭。

## 用法

```bash
bash test/run.sh        # 起靶子 → moon run src/main/transport 与 src/main/cookies → 收尾
```

也可以分开跑：

```bash
python3 test/server.py               # 默认 127.0.0.1:18777，请求日志在 stderr
moon run src/main/transport          # 自研传输层的新语义
moon run src/main/cookies            # cookie 自动维护
```

换端口：`TEST_PORT=20000 bash test/run.sh`，同时把两个示例包里
`target_base` 常量的端口同步改掉。

## 路由一览

见 [`server.py`](server.py) 文件头注释。设计约定：**每条路由都把服务端
实际收到的请求头回吐出来**（`X-Accept-Encoding`、`/echo` 的 headers、
`/final` 的 Cookie）——客户端的自我声明不算数，服务端视角才是证据。

## 范围

目前 `transport` 与 `cookies` 两个示例包打这个靶子。`src/main` 下其余
示例（basics / methods / redirect / interceptors / progress / proxy / sse）
保持自带靶子不变——它们先于此目录存在，且各自有需要外网或本地服务的段落；
后续可以把它们的本机段落逐步迁过来。
