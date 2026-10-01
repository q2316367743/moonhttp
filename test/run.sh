#!/usr/bin/env bash
# 起共享靶子 server → 跑打它的全部示例包 → 收尾。
#
# 用法：
#   bash test/run.sh                        # 跑 transport / cookies 两个离线示例包
#   TEST_PORT=18777 bash test/run.sh        # 换端口（示例包里的 target_base 常量要同步改）
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${TEST_PORT:-18777}"
LOG="test/server.log"

python3 test/server.py --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# 等靶子就绪（最多 5 秒），起不来就把日志打出来
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$PORT/status/200" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "靶子 server 启动失败，日志："
    cat "$LOG"
    exit 1
  fi
  sleep 0.1
done

echo "== 靶子 server 就绪：http://127.0.0.1:${PORT}（请求日志在 ${LOG}）=="
moon run src/main/transport
moon run src/main/cookies
