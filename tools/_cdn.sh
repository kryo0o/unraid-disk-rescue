#!/bin/bash
# 临时：测试安装地址所用 CDN 的连通性
set -u
for u in "https://cdn.jsdelivr.net" "https://fastly.jsdelivr.net" "https://gitee.com" "https://raw.githack.com"; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$u" 2>/dev/null || echo "000")
  echo "$u -> $code"
done
