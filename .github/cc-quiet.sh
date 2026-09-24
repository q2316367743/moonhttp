#!/bin/sh
# CI 专用的 C 编译器包装：给 moon 的 native 后端补一个 -Wno-unused-result。
#
# 为什么需要：依赖包 moonbitlang/async 的 C stub 在信号处理函数里**有意**忽略
# write() 的返回值（src/internal/event_loop/thread_pool.c，调用上方的注释解释了
# 为什么那次写入量有界、可以不作处理）。glibc 把 write 标成 warn_unused_result，
# 而这个告警**默认开启**（不需要 -Wall），于是 Linux/GCC 上每次编译该 stub 都会
# 刷一条告警。本机 macOS 用的是另一套 libc，不复现；上游 main 也仍是裸调用。
#
# 为什么是脚本而不是环境变量：moon 只认 MOON_CC，且它必须是一个可执行的**路径**。
# `MOON_CC="cc -Wno-unused-result"` 会被整体当成路径去找，报
# 「failed to find executable」；所以这里做一层中转。
#
# 影响范围：本仓库自己没有 C stub（`find src -name '*.c'` 为空），所以这个开关只会
# 落在依赖包的 C 代码上。unused-result 本身也是安全的一类——官方工具链调 cc 时
# 本来就带 -Wno-unused-value，这里只是照办。

exec cc -Wno-unused-result "$@"
