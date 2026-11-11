#!/bin/bash
# 临时：用 tag 地址构建 -> 推送 -> 打 tag -> 验证 CDN
set -eu
GIT="/mnt/c/Program Files/Git/cmd/git.exe"
WINREPO='D:/Documents/deepseek-harness/default-workspace/unraid-disk-rescue'
PROXY="http://127.0.0.1:10808"
REPO="kryo0o/unraid-disk-rescue"
TAG="v2026.11.12"
BASE="https://cdn.jsdelivr.net/gh/${REPO}@${TAG}"
cd "$(dirname "$0")/.."

TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | "$GIT" credential fill 2>/dev/null | sed -n 's/^password=//p')

echo "== 1. 构建（tag 地址） =="
python3 build.py --base-url "$BASE" 2>&1 | tail -3
head -9 dist/diskrescue.plg | grep -E 'pluginURL|pkgURL'
MD5=$(md5sum dist/diskrescue-2026.11.12.txz | cut -d' ' -f1)
echo "本地 MD5: $MD5"

echo "== 2. 提交并推送 =="
"$GIT" -C "$WINREPO" add -A
"$GIT" -C "$WINREPO" -c user.name="kryo0o" -c user.email="kryo0o@users.noreply.github.com" \
  commit -m "release: ${TAG}" >/dev/null 2>&1 || echo "(无变更)"
GIT_TERMINAL_PROMPT=0 "$GIT" -C "$WINREPO" \
  -c http.proxy="$PROXY" -c https.proxy="$PROXY" -c credential.helper=manager \
  push origin main 2>&1 | tail -2

SHA=$("$GIT" -C "$WINREPO" rev-parse HEAD)
echo "commit: $SHA"

echo "== 3. 打 tag =="
code=$(curl -sS -o /tmp/tag.json -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -X POST "https://api.github.com/repos/${REPO}/git/refs" \
  -d "{\"ref\":\"refs/tags/${TAG}\",\"sha\":\"${SHA}\"}")
echo "create tag HTTP $code"
if [ "$code" != "201" ]; then head -c 300 /tmp/tag.json; echo; fi

echo "== 4. 验证 CDN =="
PLG="${BASE}/dist/diskrescue.plg"
TXZ="${BASE}/dist/diskrescue-2026.11.12.txz"
for i in 1 2 3 4 5 6 7 8 9 10; do
  c1=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$PLG" || echo 000)
  c2=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$TXZ" || echo 000)
  echo "  第 $i 次: plg=$c1 txz=$c2"
  [ "$c1" = "200" ] && [ "$c2" = "200" ] && break
  sleep 4
done

curl -sS --max-time 20 "$TXZ" -o /tmp/cdn2.txz
echo "CDN MD5: $(md5sum /tmp/cdn2.txz | cut -d' ' -f1)"
curl -sS --max-time 20 "$PLG" | grep -o '<MD5>[^<]*</MD5>'
rm -f /tmp/cdn2.txz /tmp/tag.json

echo
echo "安装地址:"
echo "$PLG"
