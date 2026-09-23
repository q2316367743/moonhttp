# AGENTS.md —— 工程约束规范

## 🚫 硬性红线（违反即错）

| 编号  | 规则                                                                           |
|-------|--------------------------------------------------------------------------------|
| RL‑01 | 语言：允许英文思考，但所有对外输出必须使用中文                                 |
| RL‑02 | 根目录洁净：禁止在根目录放置业务代码                                           |
| RL‑03 | 类型安全：禁止使用 `any`；禁止不必要的 `as` 断言                               |
| RL‑04 | 文件长度：文件 ≤ 300 行，超出必须拆分                    |
| RL‑05 | 文档同步：功能实现后，必须将技术文档写入或更新 `docs/` 目录，供后续 AI 参考    |

---

## ⚙️ 编码原则

1. **方案先行**

- 需求模糊时必须提问，不做假设
- 存在多种理解时，全部列出后再确认

2. **简洁至上**

- 用最少代码解决问题
- 自检：「一位资深工程师会觉得这段代码过度设计吗？」

3. **精准修改**

- 只改必须改的部分，保持既有代码风格
- 只清理本次改动产生的孤儿代码

4. **目标驱动**

- 将任务拆成可验证目标（如：`加校验 → 先写非法输入失败用例 → 让用例通过`）

5. **文档先行落地**

- 功能实现完成后，把技术文档写入 `docs/`（新功能新建编号文档，旧功能更新对应文档）
- 文档应记录：实现思路、关键文件、数据结构 / API 契约、注意事项，供后续 AI 参考
- 新增 / 更新 / 删除文档后，必须同步更新 `docs/README.md` 索引（含标题与描述），保证索引不失效
- 需求简单、纯样式微调等无需文档的场景可豁免，但涉及逻辑 / 数据结构 / API 的变化必须记录

6. **红线优先**

- 上述原则与硬性红线冲突时，以红线为准

## 语言规范

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.
