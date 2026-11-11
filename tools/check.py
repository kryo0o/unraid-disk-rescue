#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check.py - 静态检查 + 本地功能/行为测试

用法:
    python tools/check.py
    PHP=/path/to/php NODE=/path/to/node python tools/check.py

覆盖:
    1. 文件齐全、无 CRLF
    2. bash -n / php -l / node --check
    3. 功能：复制内容、status、--skip-existing、--dry-run、路径拒绝、无参数报错
    4. 行为（慢速 dd 替身）：
       - 窗口平均速度判卡死 → 保留 .partial
       - 慢速但正常不被误杀
       - 中途停止 → .partial → 退出码 2
       - 硬卡死（无进度）→ 超时跳过 → --delete-partial 删除未完成文件
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
SCRIPT = os.path.join(APP, "scripts", "disk-rescue.sh")

problems = []
notes = []


def ok(msg):
    print("  [ok]   " + msg)


def bad(msg):
    problems.append(msg)
    print("  [FAIL] " + msg)


def skip(msg):
    notes.append(msg)
    print("  [skip] " + msg)


def find_tool(names):
    for n in names:
        if os.path.isabs(n):
            if os.path.isfile(n):
                return n
        else:
            found = shutil.which(n)
            if found:
                return found
    return None


BASH = find_tool(["bash", r"C:\Program Files\Git\bin\bash.exe",
                  r"C:\Program Files\Git\usr\bin\bash.exe", "/bin/bash"])
PHP = os.environ.get("PHP") or find_tool(["php", "php.exe", "/usr/bin/php"])
NODE = os.environ.get("NODE") or find_tool(["node", "node.exe"])


def run(cmd, **kw):
    kw.setdefault("timeout", 180)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def native_arg(tool, path):
    """在 WSL 里调用 Windows 版 node/php 时把 /mnt/... 转成 C:\\..."""
    if not tool or os.name != "posix":
        return path
    if not (tool.lower().endswith(".exe") or tool.startswith("/mnt/")):
        return path
    try:
        out = subprocess.run(["wslpath", "-w", path], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except OSError:
        pass
    return path


def check_files():
    print("[1] 文件")
    need = [
        "app/scripts/disk-rescue.sh",
        "app/include/helpers.php",
        "app/include/api.php",
        "app/include/page-body.php",
        "app/js/diskrescue.js",
        "app/js/jquery.min.js",
        "app/css/diskrescue.css",
        "docker/Dockerfile",
        "docker/entrypoint.sh",
        "docker/public/index.php",
        "docker/public/api.php",
        "docker-compose.yml",
    ]
    for rel in need:
        p = os.path.join(ROOT, rel)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            ok(rel)
        else:
            bad("缺失或为空: " + rel)

    for base, _dirs, files in os.walk(APP):
        for fn in files:
            if not fn.endswith((".sh", ".php", ".js", ".css")):
                continue
            p = os.path.join(base, fn)
            if b"\r" in open(p, "rb").read() and not fn.endswith(".min.js"):
                bad("含 CRLF: " + os.path.relpath(p, ROOT))


def check_syntax():
    print("[2] 语法")
    if BASH:
        p = run([BASH, "-n", SCRIPT])
        if p.returncode == 0:
            ok("disk-rescue.sh: bash -n")
        else:
            bad("disk-rescue.sh: " + (p.stderr or "").strip())
    else:
        skip("没有 bash")

    if PHP:
        for rel in ("app/include/helpers.php", "app/include/api.php",
                    "app/include/page-body.php", "docker/public/index.php",
                    "docker/public/api.php"):
            p = run([PHP, "-l", native_arg(PHP, os.path.join(ROOT, rel))])
            if p.returncode == 0:
                ok(rel + ": php -l")
            else:
                bad(rel + ": " + (p.stdout + p.stderr).strip())
    else:
        skip("没有 php")

    if NODE:
        p = run([NODE, "--check", native_arg(NODE, os.path.join(APP, "js", "diskrescue.js"))])
        if p.returncode == 0:
            ok("diskrescue.js: node --check")
        else:
            bad("diskrescue.js: " + (p.stderr or "").strip())
    else:
        skip("没有 node")


def check_functional():
    print("[3] 功能")
    if BASH is None:
        skip("没有 bash")
        return

    tmp = tempfile.mkdtemp(prefix="dr-func-")
    src = os.path.join(tmp, "src", "坏盘 目录")
    dst = os.path.join(tmp, "dst")
    status = os.path.join(tmp, "status")
    log = os.path.join(tmp, "run.log")
    try:
        os.makedirs(os.path.join(src, "sub1", "sub2"))
        files = {
            "a.txt": b"hello unraid\n" * 100,
            "空 格 名.bin": os.urandom(3000),
            "中文文件.dat": b"\x00\x01\x02" * 700,
            "sub1/b.txt": b"nested\n" * 500,
            "sub1/sub2/c.bin": os.urandom(5000),
        }
        for rel, data in files.items():
            with open(os.path.join(src, rel), "wb") as fh:
                fh.write(data)

        p = run([BASH, SCRIPT, "--help"])
        if p.returncode == 0 and "--src" in p.stdout:
            ok("--help")
        else:
            bad("--help 异常")

        p = run([BASH, SCRIPT], input="", timeout=20)
        if p.returncode != 0:
            ok("无参数时报错退出（rc=%d）" % p.returncode)
        else:
            bad("无参数时没有报错")

        p = run([BASH, SCRIPT, "--src", src, "--dst", dst, "--yes",
                 "--min-speed", "0", "--check", "1",
                 "--status-file", status, "--log-file", log])
        if p.returncode != 0:
            bad("复制测试 rc=%d" % p.returncode)
        else:
            ok("复制测试 rc=0")

        for rel, data in files.items():
            got = os.path.join(dst, rel)
            if not os.path.isfile(got):
                bad("目标缺少: " + rel)
            elif open(got, "rb").read() != data:
                bad("内容不一致: " + rel)
        ok("内容逐一比对")

        if os.path.isfile(status):
            kv = {}
            for line in open(status, encoding="utf-8"):
                if "=" in line:
                    k, v = line.split("=", 1)
                    kv[k.strip()] = v.strip()
            if kv.get("total") == "5" and kv.get("ok") == "5" and kv.get("state") == "finished":
                ok("status 计数正确")
            else:
                bad("status 异常: %s" % kv)
        else:
            bad("没有 status 文件")

        p = run([BASH, SCRIPT, "--src", src, "--dst", dst, "--yes", "--skip-existing",
                 "--min-speed", "0", "--check", "1", "--status-file", status, "--log-file", log])
        if p.returncode == 0 and "跳过" in open(log, encoding="utf-8", errors="replace").read():
            ok("--skip-existing")
        else:
            bad("--skip-existing rc=%d" % p.returncode)

        inner = os.path.join(src, "sub1", "out")
        p = run([BASH, SCRIPT, "--src", src, "--dst", inner, "--yes", "--min-speed", "0",
                 "--status-file", status, "--log-file", log])
        if p.returncode != 0 and "内部" in open(log, encoding="utf-8", errors="replace").read():
            ok("拒绝目标在源内")
        else:
            bad("未拒绝目标在源内")

        p = run([BASH, SCRIPT, "--src", src, "--dst", src, "--yes", "--min-speed", "0",
                 "--status-file", status, "--log-file", log])
        if p.returncode != 0:
            ok("拒绝源=目标")
        else:
            bad("未拒绝源=目标")

        dry = os.path.join(tmp, "dry")
        p = run([BASH, SCRIPT, "--src", src, "--dst", dry, "--yes", "--dry-run",
                 "--status-file", status, "--log-file", log])
        copied = []
        for dp, _d, fns in os.walk(dry):
            for fn in fns:
                if fn != "disk-rescue-failed.txt":
                    copied.append(fn)
        if p.returncode == 0 and not copied:
            ok("--dry-run 不复制")
        else:
            bad("--dry-run 异常: %s" % copied)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def shim_dd(path, mode):
    body = {
        "slow": """#!/bin/bash
for a in "$@"; do
  case "$a" in
    --help) echo "status=progress"; exit 0 ;;
    if=*) IF="${a#if=}" ;; of=*) OF="${a#of=}" ;; esac
done
total=$(stat -c %s "$IF" 2>/dev/null || echo 0)
: > "$OF"; i=0; written=0
while [ "$written" -lt "$total" ]; do
  /bin/dd if="$IF" of="$OF" bs=1M count=1 skip="$i" seek="$i" conv=notrunc 2>/dev/null || exit 1
  written=$((written + 1048576)); i=$((i + 1))
  printf '%d bytes (1.0 MB) copied, 0.25 s, 4.2 MB/s\\n' "$written" >&2
  sleep 0.25
done
""",
        "hang": """#!/bin/bash
for a in "$@"; do
  case "$a" in
    --help) echo "status=progress"; exit 0 ;;
    if=*) IF="${a#if=}" ;; of=*) OF="${a#of=}" ;; esac
done
: > "$OF"
/bin/dd if="$IF" of="$OF" bs=1M count=1 2>/dev/null
printf '1048576 bytes (1.0 MB) copied\\n' >&2
sleep 300
""",
    }[mode]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)
    os.chmod(path, 0o755)


def check_behavior():
    print("[4] 行为（慢速 dd 替身）")
    if BASH is None:
        skip("没有 bash")
        return
    import signal

    tmp = tempfile.mkdtemp(prefix="dr-behav-")
    shim = os.path.join(tmp, "bin")
    os.makedirs(shim)
    env = dict(os.environ)
    env["PATH"] = shim + os.pathsep + env.get("PATH", "")

    def scenario(tag):
        s = os.path.join(tmp, tag, "src")
        d = os.path.join(tmp, tag, "dst")
        os.makedirs(s)
        os.makedirs(d)
        return s, d, os.path.join(tmp, tag, "run.log"), os.path.join(tmp, tag, "status")

    try:
        # 1) 窗口平均速度判卡死
        shim_dd(os.path.join(shim, "dd"), "slow")
        s, d, lg, st = scenario("stall")
        with open(os.path.join(s, "big.bin"), "wb") as fh:
            fh.write(b"\0" * (64 * 1024 * 1024))
        p = run([BASH, SCRIPT, "--src", s, "--dst", d, "--yes",
                 "--min-speed", "100", "--speed-window", "10", "--check", "1",
                 "--max-stall", "1", "--grace-factor", "0",
                 "--status-file", st, "--log-file", lg], env=env)
        txt = open(lg, encoding="utf-8", errors="replace").read() if os.path.isfile(lg) else ""
        if p.returncode == 3 and os.path.isfile(os.path.join(d, "big.bin.partial")):
            ok("卡死判定：rc=3 且保留 .partial")
        else:
            bad("卡死判定：rc=%d" % p.returncode)
        if "最近" in txt and "判定卡死" in txt:
            ok("卡死判定：日志有窗口速度与原因")
        else:
            bad("卡死判定：日志不完整")

        # 2) 慢速但正常
        s, d, lg, st = scenario("slowok")
        with open(os.path.join(s, "ok.bin"), "wb") as fh:
            fh.write(b"\0" * (48 * 1024 * 1024))
        p = run([BASH, SCRIPT, "--src", s, "--dst", d, "--yes",
                 "--min-speed", "1", "--speed-window", "10", "--check", "1",
                 "--max-stall", "1", "--grace-factor", "0",
                 "--status-file", st, "--log-file", lg], env=env)
        target = os.path.join(d, "ok.bin")
        if p.returncode == 0 and os.path.isfile(target) and os.path.getsize(target) == 48 * 1024 * 1024:
            ok("慢速正常：未被误杀")
        else:
            bad("慢速正常：rc=%d" % p.returncode)

        # 3) 中途停止
        s, d, lg, st = scenario("stop")
        with open(os.path.join(s, "stop.bin"), "wb") as fh:
            fh.write(b"\0" * (32 * 1024 * 1024))
        proc = subprocess.Popen(
            [BASH, SCRIPT, "--src", s, "--dst", d, "--yes", "--min-speed", "0",
             "--check", "1", "--status-file", st, "--log-file", lg],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(5)
        proc.send_signal(signal.SIGTERM)
        try:
            rc = proc.wait(timeout=40)
        except subprocess.TimeoutExpired:
            proc.kill()
            rc = -1
        stxt = open(st, encoding="utf-8", errors="replace").read() if os.path.isfile(st) else ""
        if rc == 2 and "state=stopped" in stxt and os.path.isfile(os.path.join(d, "stop.bin.partial")):
            ok("停止：rc=2 / stopped / 保留 .partial")
        else:
            bad("停止：rc=%d state=%s" % (rc, "stopped" if "state=stopped" in stxt else "?"))

        # 4) 硬卡死 + 删除未完成文件
        shim_dd(os.path.join(shim, "dd"), "hang")
        s, d, lg, st = scenario("hang")
        with open(os.path.join(s, "hang.bin"), "wb") as fh:
            fh.write(b"\0" * (8 * 1024 * 1024))
        p = run([BASH, SCRIPT, "--src", s, "--dst", d, "--yes",
                 "--min-speed", "0", "--hang-timeout", "3", "--check", "1",
                 "--delete-partial", "--grace-factor", "0",
                 "--status-file", st, "--log-file", lg], env=env)
        txt = open(lg, encoding="utf-8", errors="replace").read() if os.path.isfile(lg) else ""
        left = [f for f in os.listdir(d) if f.endswith(".partial")]
        if p.returncode == 3 and not left and "没有任何进度" in txt:
            ok("硬卡死：无进度 3s 跳过 + 删除未完成文件")
        else:
            bad("硬卡死：rc=%d left=%s" % (p.returncode, left))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    print("== diskrescue 检查 ==\n")
    check_files()
    check_syntax()
    check_functional()
    check_behavior()

    print("\n== 结果 ==")
    for n in notes:
        print("  note: " + n)
    if problems:
        print("  %d 个问题:" % len(problems))
        for p in problems:
            print("   - " + p)
        return 1
    print("  全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
