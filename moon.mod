// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "q2316367743/moonhttp"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/q2316367743/moonhttp"

license = "Apache-2.0"

keywords = [ "http", "client", "axios", "async", "sse", "networking" ]

// HTTP 请求最终要靠 moonbitlang/async 的异步运行时发出去。
// 该包官方偏好 native 后端（wasm1 上的异步支持仍标注为实验性），
// 所以本模块也以 native 为默认构建目标。

preferred_target = "native"

// 业务代码全部放在 src/ 下：模块根包即 src/ 本身，
// 根目录只保留模块元数据与文档（见 AGENTS.md 的 RL-02）。

source = "src"

description = "axios 风格的 MoonBit HTTP 客户端：实例与配置合并、四种请求体形态、流式与 SSE、自动重定向"

import {
  "moonbitlang/async@0.22.2",
}
