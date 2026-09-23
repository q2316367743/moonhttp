# 技术文档索引

本目录记录 `easy-http-client` 的实现思路、关键文件、数据结构 / API 契约与注意事项，供后续开发（含 AI 协作）快速接管。

面向使用者的入门文档在仓库根目录的 [README.mbt.md](../README.mbt.md)；本目录面向维护者，重点回答「为什么这样设计」和「改动时要同步什么」。

| 编号 | 文档 | 内容 | 什么时候读 |
|---|---|---|---|
| 01 | [架构与分层](01-architecture.md) | 目录结构、六个包的职责与依赖方向、为什么把 async 关在一层、如何新增一个配置字段或一个新包 | 要动手改代码之前 |
| 02 | [配置合并契约](02-config-merge.md) | axios `mergeConfig` 四种策略在本项目的落法、字段归属表、`Option` 与 `undefined` 的对应、数组替换语义 | 要改合并行为、或要新增配置字段时 |
| 03 | [请求管线](03-request-pipeline.md) | `request` 的八个步骤、URL 拼接与 query 序列化规则、body 序列化与自动补头、状态码校验 | 要改请求行为（URL、头的优先级、body 处理）时 |
| 04 | [错误契约](04-errors.md) | `HttpError` / `ErrorCode` 形状、与 axios 错误码的对应、各类错误的触发点、错误里带什么上下文 | 要新增错误分类或调整错误信息时 |
| 05 | [传输层契约](05-transport.md) | `Transport` trait 与 `PreparedRequest` / `RawResponse` 字段含义、`AsyncHttpTransport` 的实现注意事项、如何写自定义传输 | 要换 HTTP 实现、加连接池 / 代理 / 进度回调时 |

## 改动时的同步清单

改代码时容易被漏掉的联动项，集中写在这里：

1. **新增配置字段**：`Config` 加字段 → 在 `merge_config` 里显式选一档合并策略 → 需要的话加 `with_*` 构建器与 `Config::to_string` 渲染 → 若参与请求，接到 `build_prepared_request` 或 `build_response` → 补测试（`merge` 包测合并、根包测端到端）→ 更新 `02-config-merge.md` 的字段归属表。
2. **新增包**：确认依赖方向仍是 DAG（见 `01-architecture.md`）→ 新包若暴露新类型，用 `pub using` 再导出 → 根包 `moon.pkg` 加 import → 更新 README 与 `01-architecture.md` 的目录树。
3. **改公开 API**：跑 `moon info` 后检查 `pkg.generated.mbti` 的 diff，确认只包含预期的变化。
4. **对接底层库（`moonbitlang/async`）的改动**：只允许出现在 `src/transport/async_http.mbt`；如果发现必须让上层认识底层类型，说明抽象漏了，应当先补 `Transport` 契约。
