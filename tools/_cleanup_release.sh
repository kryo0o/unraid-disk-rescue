#!/bin/bash
# 临时：清理发布脚本 -> 移动 tag -> 最终验证
set -eu
GIT="/mnt/c/Program Files/Git/cmd/git.exe"
WINREPO='D:/Documents/deepseek-harness/default-workspace/unraid-disk-rescue'
PROXY="http://127.0.0.1:10808"
REPO="kryo0o/unraid-disk-rescue"
TAG="v2026.11.12"
BASE="https://cdn.jsdelivr.net/gh/${REPO}@${TAG}"
cd "$(dirname "$0")/.."

TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | "$GIT" credential fill 2>/dev/null | sed -n 's/^password=//p')

rm -f tools/_release.sh tools/_finalize.sh
"$GIT" -C "$WINREPO" rm --cached -q tools/_release.sh 2>/dev/null || true
"$GIT" -C "$WINREPO" add -A
"$GIT" -C "$WINREPO" -c user.name="kryo0o" -c user.email="kryo0o@users.noreply.github.com" \
  commit -m "chore: 清理临时脚本" >/dev/null 2>&1 || echo "(无变更)"
GIT_TERMINAL_PROMPT=0 "$GIT" -C "$WINREPO" \
  -c http.proxy="$PROXY" -c https.proxy="$PROXY" -c credential.helper=manager \
  push origin main 2>&1 | tail -2

SHA=$("$GIT" -C "$WINREPO" rev-parse HEAD)
echo "新 commit: $SHA"

# 把 tag 移到干净提交
curl -sS -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/${REPO}/git/refs/tags/${TAG}" || true
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/${REPO}/git/refs" \
  -d "{\"ref\":\"refs/tags/${TAG}\",\"sha\":\"${SHA}\"}")
echo "重建 tag HTTP $code"

echo "== 最终验证 =="
for u in "${BASE}/dist/diskrescue.plg" "${BASE}/dist/diskrescue-2026.11.12.txz" "${BASE}/icons/diskrescue.png"; do
  printf '%s -> ' "$u"
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 25 "$u" || echo fail
done
curl -sS --max-time 25 "${BASE}/dist/diskrescue-2026.11.12.txz" -o /tmp/f.txz
echo "CDN txz MD5: $(md5sum /tmp/f.txz | cut -d' ' -f1)"
curl -sS --max-time 25 "${BASE}/dist/diskrescue.plg" | grep -o '<MD5>[^<]*</MD5>'
rm -f /tmp/f.txz

echo "== 仓库文件列表（根） =="
curl -sS -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/${REPO}/contents/" \
  | python3 -c 'import json,sys; [print(" ", x["name"]) for x in json.load(sys.stdin)]'
