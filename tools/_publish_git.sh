#!/bin/bash
# 临时：创建仓库 -> 用 CDN 地址构建 -> git 推送（走系统代理）
set -eu
GIT="/mnt/c/Program Files/Git/cmd/git.exe"
WINREPO='D:/Documents/deepseek-harness/default-workspace/unraid-disk-rescue'
REPO="kryo0o/unraid-disk-rescue"
PROXY="http://127.0.0.1:10808"
cd "$(dirname "$0")/.."

TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | "$GIT" credential fill 2>/dev/null | sed -n 's/^password=//p')
[ -n "$TOKEN" ] || { echo "没有可用凭据"; exit 1; }

echo "== 1. 创建仓库 =="
code=$(curl -sS -o /tmp/repo.json -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  -X POST https://api.github.com/user/repos \
  -d '{"name":"unraid-disk-rescue","private":false,"description":"Unraid 坏盘数据抢救插件（diskrescue）：窗口平均速度判定、可调宽限、保留 .partial"}')
echo "HTTP $code"
if [ "$code" != "201" ] && [ "$code" != "422" ]; then
  head -c 400 /tmp/repo.json; echo; exit 1
fi

echo "== 2. 用 CDN 地址重建清单 =="
python3 build.py --base-url "https://cdn.jsdelivr.net/gh/${REPO}@main" 2>&1 | tail -4
grep -o 'https://cdn.jsdelivr.net[^"<]*' dist/diskrescue.plg | head -3

echo "== 3. 提交并推送 =="
cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.tmp/
.DS_Store
EOF
if [ ! -d .git ]; then
  "$GIT" -C "$WINREPO" init -b main >/dev/null
fi
"$GIT" -C "$WINREPO" add -A
"$GIT" -C "$WINREPO" -c user.name="kryo0o" -c user.email="kryo0o@users.noreply.github.com" \
  commit -m "diskrescue 2026.11.12: 窗口平均速度判定 + 可调宽限 + 路径持久化" >/dev/null || echo "(没有新变更)"
"$GIT" -C "$WINREPO" remote remove origin 2>/dev/null || true
"$GIT" -C "$WINREPO" remote add origin "https://github.com/${REPO}.git"
GIT_TERMINAL_PROMPT=0 "$GIT" -C "$WINREPO" \
  -c http.proxy="$PROXY" -c https.proxy="$PROXY" \
  -c credential.helper=manager \
  push -u origin main 2>&1 | tail -6
echo "push exit=$?"
