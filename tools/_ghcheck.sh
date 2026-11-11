#!/bin/bash
# 临时：读取已保存的 GitHub 凭据 -> 查账号 / 仓库是否存在（不打印 token）
set -u
GIT="/mnt/c/Program Files/Git/cmd/git.exe"
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | "$GIT" credential fill 2>/dev/null | sed -n 's/^password=//p')
if [ -z "$TOKEN" ]; then echo "NO_TOKEN"; exit 1; fi
echo "token: found (${#TOKEN} chars)"

api() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

login=$(api https://api.github.com/user | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("login",""))')
if [ -z "$login" ]; then
  echo "API 认证失败，尝试 token 前缀"
  api -H "Authorization: token $TOKEN" https://api.github.com/user | head -c 200
  exit 1
fi
echo "login: $login"

code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$login/disk-rescue")
echo "repo $login/disk-rescue -> $code"
code2=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$login/unraid-disk-rescue")
echo "repo $login/unraid-disk-rescue -> $code2"
