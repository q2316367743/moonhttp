# 16 自定义 HTTP 方法（WebDAV 等）：本期不支持的原因与解锁路径

**一句话**：自定义方法（WebDAV 的 `PROPFIND` 等）本期发不出去——瓶颈不在本项目的 `Method` 设计，
而在底层 `moonbitlang/async/http` 的 `RequestMethod` 同样是封闭枚举、且公开 API 没有任何「字符串方法」入口；
2026-09-29 决策：**代码不动，向 `moonbitlang/async` 提 issue 推上游**。本文记录调研证据、被排除的绕行路线，
以及上游解锁后本项目的最小改动方案（保证届时用户代码与本文档承诺的 API 形态零返工）。

## 约束证据（2026-09-29 逐条核实，改动前先复核是否仍然成立）

1. **本项目这一层不是障碍**：`src/config/method.mbt` 的 `Method` 是 9 构造器封闭枚举，但它是 `pub(all)`，
   加一个带载荷的 `Other(String)` 变体即可表达任意方法。全链路核查结论：
   - 配置合并（`merge.mbt` 的 `http_method` 走「只取请求级」）、`method_headers : Map[Method, Headers]`
     （`Eq`/`Hash` derive 对 String 载荷自动生效）、`Config::to_string` 渲染，全部无需改动；
   - 重定向（`src/config/redirect.mbt` 的 `rewrites_to_get`）只认 `Post`（301/302 改 GET）与非 `Get`/`Head`（303 改 GET）——
     `Other` 在 301/302 保持原方法、303 落进「非 GET/HEAD → GET」分支，均符合 RFC 语义，**现有代码天然兼容**；
   - `MockTransport` 不解释方法，测试侧也免改。
2. **底层（`moonbitlang/async@0.22.2`，`src/transport` 是全模块唯一 import 它的包）三处证据**：
   - `src/http/types.mbt`：`RequestMethod` 是 `pub(all)` 封闭枚举（9 构造器），第三方无法增删构造器；
     上游 GitHub main 分支（晚于 0.22.4）核实过，同样如此；
   - `src/http/client.mbt`：`Client::request(Self, RequestMethod, StringView, extra_headers?)` 只收枚举；
     全量 `pkg.generated.mbti` 里没有任何字符串方法入口（`Request.meth` 已 deprecated，且也是枚举类型）；
   - `src/http/send.mbt` 的 `Sender::send_request`：match 枚举逐个写死请求行（`"GET "` / `"POST "` / …），
     是包内唯一写请求行的地方——上游要支持任意方法，绕不开改这里。
3. **服务端同样封闭**：`src/http/parser.mbt` 的 `Reader::read_request` 对方法 token 穷尽 match，
   未知方法直接 `raise BadRequest`。也就是说用 `moonbitlang/async` 写的 HTTP 服务端也收不了 WebDAV 请求——
   提 issue 时值得把两侧一起提。
4. **`moon` 没有「给依赖持久打补丁」的机制**：`moon check/test --patch-file` 只是「测试期对单个包做文件覆盖」，
   不参与 build / install，不能当依赖补丁用。别再往这条路调研。

## 被排除的绕行路线

| 路线 | 结论 |
|---|---|
| fork `http` 包进本仓库、补上字符串方法 | 非测试代码约 2700 行（parser 447 + send 391 + client 355 + …），需跟随上游升级；评审与维护都是负担，黑客松截止日前不可行 |
| 从 `@socket` / `@tls` 自写第二个 HTTP 客户端 | 等于重写 HTTP/1.1 栈（请求行、chunked、TLS、gzip、响应解析、连接生命周期），重复造轮子，放弃 |
| `Client` 上找旁路自己写请求行 | 不可行：`Client` 是 opaque 类型，拿不到底层 socket；响应解析器（`parser.mbt`）也是包私有，请求与响应两头都绕不开 |
| 等 `moon patch` 类机制 | 该机制不存在（见上） |

## 上游解锁后的实施方案（一次改完的清单）

上游给任意形状的支持后（`Other(String)` 变体或 `Client::request_raw(method : String, ...)` 均可）：

1. `src/config/method.mbt`：`Method` 加 `Other(String)`。**存原样、发原样**——HTTP 方法 token 按 RFC 7230
   区分大小写，惯例大写由调用方保证；`to_string` 对 `Other` 返回载荷本身。`Method::parse` 保持
   「未知返回 `None`」的严格语义不变（生产代码没人调它，唯一调用在测试）。
2. `src/transport/async_http.mbt`：`to_request_method` 覆盖 `Other` 分支映射到上游新入口；
   发送前对 token 字符做一次 RFC 7230 校验（防拼坏请求行），非法字符在**建连前**报错。
3. 错误面：本期未实现，故没有为它新增错误码。若未来要在「上游解锁前」先行开放 API（`Method::Other` +
   发送时报错），新增 `ErrorCode::NotImplemented`（`ERR_NOT_IMPLEMENTED`）即可，别复用网络类错误码。
4. 同步 `docs/05-transport.md` 的「枚举映射」、本文档的状态、`README.mbt.md` 的「暂不支持」清单；
   白盒用例直测 `to_request_method`，端到端用例用本机 server 发一个 `PROPFIND`。

## 上游 issue 草稿（英文全文，提交与否由 owner 决定）

标题：`http: support extension request methods (WebDAV PROPFIND, REPORT, custom API methods)`

```text
### Problem

`RequestMethod` in `moonbitlang/async/http` is a closed enum holding exactly the nine
standard methods. `Client::request` only accepts this enum, and internally
`Sender::send_request` (src/http/send.mbt) matches on it to write the request line.
There is no public API that accepts a raw method name, so extension methods cannot be sent:

- WebDAV (RFC 4918): PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK
- Versioned editing (RFC 3253): REPORT, VERSION-CHECKOUT, etc.
- Custom methods used by API gateways and internal protocols

The server side is closed the same way: `Reader::read_request` (src/http/parser.mbt)
matches the method token exhaustively and raises `BadRequest` for anything unknown,
so a `moonbitlang/async` HTTP server cannot receive WebDAV requests either.

For comparison, raw methods are the norm elsewhere: Go's `http.NewRequest(method string, ...)`,
Rust reqwest's `Method::from_bytes`, Node.js `http.request({ method })`, and axios/fetch
all accept arbitrary method names.

### Proposal (either would unblock us)

1. Add an `Other(String)` variant to `RequestMethod`:
   - client: `Sender::send_request` writes the payload verbatim as the request-line token;
     optionally validate it against the RFC 7230 `tchar` set and reject malformed tokens.
   - parser: `should_not_have_body` treats unknown methods conservatively
     (fall through to the existing status-code-based rules).
   - server: `Reader::read_request` parses unknown tokens into `Other(name)`.
   The existing `derive(Eq, Hash, ToJson)` keeps working with a payload variant.
2. Or, minimal intrusion: a raw-method entry point such as
   `Client::request_raw(method : String, path : StringView, extra_headers? : Headers) -Unit`,
   implemented by generalizing `Sender::send_request` to take the token as a string.

Happy to follow up with a PR if the direction is agreed.
```
