#!/bin/bash
# 临时：检测 GitHub 连通性与可用代理
set -u
echo "--- curl github.com ---"
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 12 https://github.com || echo "failed"
echo "--- curl api.github.com ---"
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 12 https://api.github.com || echo "failed"
echo "--- git ls-remote ---"
timeout 30 git ls-remote https://github.com/git/git.git HEAD 2>&1 | head -3
echo "rc=$?"
echo "--- proxy env ---"
env | grep -i proxy | sed 's/=.*/=<set>/' || echo "(none)"
echo "--- windows git proxy ---"
'/mnt/c/Program Files/Git/cmd/git.exe' config --global --get http.proxy || echo "(none)"
echo "--- windows git https proxy ---"
'/mnt/c/Program Files/Git/cmd/git.exe' config --global --get https.proxy || echo "(none)"
echo "--- host ip ---"
ip route 2>/dev/null | awk '/default/ {print $3; exit}'
grep nameserver /etc/resolv.conf 2>/dev/null | head -1
echo "--- 探测常见代理端口 ---"
HOST=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
for p in 7890 7897 10809 1080 8080; do
  if timeout 2 bash -c "</dev/tcp/$HOST/$p" 2>/dev/null; then
    echo "open: $HOST:$p"
  fi
done
