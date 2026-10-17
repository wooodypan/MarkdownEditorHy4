#!/bin/bash
# 启动本机测试执行服务。
# 必须用 open -n 交给 launchd 拉起；从终端里直接 python3 server.py & 会继承调用者的沙盒。

cd "$(dirname "$0")" || exit 1

API="http://127.0.0.1:8765"

# 显式绕开 HTTP 代理。系统代理的 no_proxy 未必包含 127.0.0.1，
# 走代理时后端没起来只会拿到一个错误页，curl 照样返回成功，判断就错了。
probe() {
  curl -fs --noproxy '*' --max-time 2 "$API/health" >/dev/null 2>&1
}

if probe; then
  echo "服务已经在跑了"
  curl -s --noproxy '*' "$API/health"
  echo
  exit 0
fi

open -n "$(pwd)/TestRunnerServer.app"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.5
  if probe; then
    echo "已启动"
    curl -s --noproxy '*' "$API/health"
    echo
    exit 0
  fi
done

echo "启动失败，看 /tmp/mdhy4-testrunner.log" >&2
tail -20 /tmp/mdhy4-testrunner.log >&2
exit 1
