#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
publish.py - 通过 GitHub REST API 发布插件（不需要 git push，适合 github.com 被墙的环境）

用法:
    GITHUB_TOKEN=xxx python3 tools/publish.py --repo <owner>/<name> [--branch main]

做的事:
    1. 校验 token / 仓库（不存在则尝试创建公开仓库）
    2. 用 Contents API 上传源码、打包产物
    3. 以 jsDelivr 为 base-url 重新生成 dist/diskrescue.plg 并上传
    4. 输出可直接粘贴到 Unraid「Install Plugin」的地址

说明:
    - 只依赖标准库（urllib），不需要 requests
    - 单文件 < 100MB（本插件约 30KB）
    - token 建议用 fine-grained：仅目标仓库、Contents: Read and write
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://api.github.com"
PLUGIN = "diskrescue"

# 上传哪些文件（相对仓库根目录）
INCLUDE_DIRS = ["package", "dist", "tools", "icons"]
INCLUDE_FILES = ["README.md", "build.py", "build.sh", "diskrescue.plg.in", "package/usr"]
SKIP_SUFFIX = (".pyc",)
SKIP_NAMES = {".DS_Store", "Thumbs.db"}


def api(method, path, token, payload=None, raw=False):
    url = API + path if path.startswith("/") else path
    data = None
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "diskrescue-publisher",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return resp.status, (body if raw else json.loads(body.decode("utf-8") or "{}"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body)
        except Exception:  # noqa: BLE001
            parsed = {"message": body}
        return exc.code, parsed


def collect_files():
    files = []
    for d in INCLUDE_DIRS:
        base = os.path.join(ROOT, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(x for x in dirnames if x not in (".git", "__pycache__"))
            for fn in sorted(filenames):
                if fn in SKIP_NAMES or fn.endswith(SKIP_SUFFIX):
                    continue
                full = os.path.join(dirpath, fn)
                files.append(os.path.relpath(full, ROOT).replace("\\", "/"))
    for f in INCLUDE_FILES:
        full = os.path.join(ROOT, f)
        if os.path.isfile(full) and f not in files:
            files.append(f)
    return sorted(set(files))


def put_file(repo, branch, path, token, message):
    full = os.path.join(ROOT, path)
    with open(full, "rb") as fh:
        content = base64.b64encode(fh.read()).decode("ascii")
    payload = {"message": message, "content": content, "branch": branch}

    # 已存在则需要 sha 才能更新
    st, info = api("GET", "/repos/%s/contents/%s?ref=%s" % (repo, path, branch), token)
    if st == 200 and isinstance(info, dict) and info.get("sha"):
        payload["sha"] = info["sha"]
    st, info = api("PUT", "/repos/%s/contents/%s" % (repo, path), token, payload)
    if st in (200, 201):
        return True
    print("    ! %s 失败: %s %s" % (path, st, info.get("message", "")))
    return False


def ensure_repo(repo, token):
    st, info = api("GET", "/repos/" + repo, token)
    if st == 200:
        return info.get("default_branch") or "main", info.get("html_url", "")
    if st == 404:
        name = repo.split("/", 1)[1]
        st2, info2 = api("POST", "/user/repos", token, {
            "name": name,
            "private": False,
            "description": "Unraid 坏盘数据抢救插件（diskrescue）",
            "auto_init": False,
        })
        if st2 in (200, 201):
            print("[publish] 已创建公开仓库 %s" % repo)
            return info2.get("default_branch") or "main", info2.get("html_url", "")
        print("[publish] 无法创建仓库（%s %s）" % (st2, info2.get("message", "")))
        print("[publish] 请先在网页上建一个空仓库，再重跑本命令")
        sys.exit(1)
    print("[publish] 访问仓库失败: %s %s" % (st, info.get("message", "")))
    sys.exit(1)


def build_plg(cdn_base):
    """用 jsDelivr 地址重新构建 dist/diskrescue.plg"""
    cmd = [sys.executable, os.path.join(ROOT, "build.py"), "--base-url", cdn_base]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout)
        print(proc.stderr)
        sys.exit(1)
    return proc.stdout.strip().splitlines()[-1]


def cdn_ready(url, tries=10):
    for i in range(tries):
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "curl/8"})
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                if resp.status == 200:
                    return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(3)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--branch", default="", help="默认取仓库 default_branch")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    args = ap.parse_args()

    if not args.token:
        print("缺少 token：用 GITHUB_TOKEN 环境变量传入")
        sys.exit(1)
    if "/" not in args.repo:
        print("--repo 需要 owner/name 格式")
        sys.exit(1)

    st, me = api("GET", "/user", args.token)
    if st != 200:
        print("token 无效或权限不足: %s %s" % (st, me.get("message", "")))
        sys.exit(1)
    print("[publish] 账号: %s" % me.get("login"))

    branch, html_url = ensure_repo(args.repo, args.token)
    if args.branch:
        branch = args.branch
    print("[publish] 仓库: https://github.com/%s  分支: %s" % (args.repo, branch))

    files = collect_files()
    print("[publish] 上传 %d 个文件 ..." % len(files))
    ok = 0
    for path in files:
        if put_file(args.repo, branch, path, args.token, "add " + path):
            ok += 1
    print("[publish] 已上传 %d/%d" % (ok, len(files)))

    cdn_base = "https://cdn.jsdelivr.net/gh/%s@%s" % (args.repo, branch)
    print("[publish] 用 CDN 地址重建清单: %s" % cdn_base)
    build_plg(cdn_base)

    # plg 需要用 CDN 地址重传
    for path in ("dist/diskrescue.plg", "dist/diskrescue-local.plg"):
        put_file(args.repo, branch, path, args.token, "update " + path)

    plg_url = "%s/dist/diskrescue.plg" % cdn_base
    pkg_url = "%s/dist/%s-2026.11.12.txz" % (cdn_base, PLUGIN)
    print()
    print("== 安装地址（粘贴到 Unraid -> Plugins -> Install Plugin）==")
    print(plg_url)
    print()
    print("[publish] 校验 CDN ...")
    print("  plg: %s" % ("OK" if cdn_ready(plg_url) else "尚未生效（jsDelivr 首次抓取可能要等几秒）"))
    print("  txz: %s" % ("OK" if cdn_ready(pkg_url) else "尚未生效"))
    print()
    print("仓库页面: %s" % (html_url or ("https://github.com/" + args.repo)))


if __name__ == "__main__":
    main()
