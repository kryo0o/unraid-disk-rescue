#!/bin/bash
# 临时：清理临时脚本 -> 校验 LF -> 再推送 -> 验证 CDN
set -eu
GIT="/mnt/c/Program Files/Git/cmd/git.exe"
WINREPO='D:/Documents/deepseek-harness/default-workspace/unraid-disk-rescue'
PROXY="http://127.0.0.1:10808"
cd "$(dirname "$0")/.."

echo "== 1. 删除临时脚本 =="
rm -f tools/_net.sh tools/_cdn.sh tools/_ghcheck.sh tools/_publish_git.sh
"$GIT" -C "$WINREPO" rm --cached -q tools/_net.sh tools/_cdn.sh tools/_ghcheck.sh tools/_publish_git.sh 2>/dev/null || true
rm -f tools/_net.sh tools/_cdn.sh tools/_ghcheck.sh tools/_publish_git.sh

echo "== 2. 校验仓库里的换行 =="
for f in package/usr/local/emhttp/plugins/diskrescue/scripts/disk-rescue.sh dist/diskrescue.plg; do
  if "$GIT" -C "$WINREPO" show "HEAD:$f" 2>/dev/null | grep -q $'\r'; then
    echo "  CRLF! $f"
  else
    echo "  LF ok $f"
  fi
done

echo "== 3. 提交并推送 =="
"$GIT" -C "$WINREPO" add -A
"$GIT" -C "$WINREPO" -c user.name="kryo0o" -c user.email="kryo0o@users.noreply.github.com" \
  commit -m "chore: 移除临时调试脚本" >/dev/null 2>&1 || echo "(无变更)"
GIT_TERMINAL_PROMPT=0 "$GIT" -C "$WINREPO" \
  -c http.proxy="$PROXY" -c https.proxy="$PROXY" -c credential.helper=manager \
  push origin main 2>&1 | tail -3

echo "== 4. 等待 jsDelivr 抓取 =="
PLG="https://cdn.jsdelivr.net/gh/kryo0o/unraid-disk-rescue@main/dist/diskrescue.plg"
TXZ="https://cdn.jsdelivr.net/gh/kryo0o/unraid-disk-rescue@main/dist/diskrescue-2026.11.12.txz"
for i in 1 2 3 4 5 6 7 8; do
  c1=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$PLG" || echo 000)
  c2=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$TXZ" || echo 000)
  echo "  第 $i 次: plg=$c1 txz=$c2"
  [ "$c1" = "200" ] && [ "$c2" = "200" ] && break
  sleep 5
done

echo "== 5. CDN 内容抽查 =="
curl -sS --max-time 20 "$PLG" | grep -E 'ENTITY (version|pkgURL)|<MD5>' | head -3
curl -sS --max-time 20 "$TXZ" -o /tmp/cdn.txz && md5sum /tmp/cdn.txz && rm -f /tmp/cdn.txz
