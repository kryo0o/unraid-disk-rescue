#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check.py - 静态检查 + 本地功能测试（在开发机上运行）

用法:
    python tools/check.py

检查项:
    1. .plg 结构（PLUGIN 属性、实体声明、INLINE 片段 bash 语法）
    2. 包内文件齐全、文本文件为 LF
    3. bash 脚本 `bash -n` 语法
    4. PHP 文件 `php -l`（有 php 时）
    5. JS 文件 `node --check`（有 node 时）
    6. 功能测试：用临时目录跑一遍 disk-rescue.sh
         - --help 正常
         - 不带参数时（非交互）报错退出
         - --dry-run 预扫描
         - 正常复制（含中文名、空格名、嵌套目录）
         - --skip-existing 断点续跑
         - 同源/目标相同、目标在源内 的拒绝逻辑
         - status 文件字段完整
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLG = os.path.join(ROOT, "diskrescue.plg")
BASE = os.path.join(ROOT, "package", "usr", "local", "emhttp", "plugins", "diskrescue")
SCRIPT = os.path.join(BASE, "scripts", "disk-rescue.sh")

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
    kw.setdefault("timeout", 120)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def native_arg(tool, path):
    """在 WSL 里调用 Windows 版 node/php 时，把 /mnt/... 转成 C:\\... 形式。"""
    if not tool or os.name != "posix":
        return path
    win_like = tool.lower().endswith(".exe") or tool.startswith("/mnt/")
    if not win_like:
        return path
    try:
        out = subprocess.run(["wslpath", "-w", path], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except OSError:
        pass
    return path


# --------------------------------------------------------------------------
def check_plg():
    print("[1] .plg 结构")
    if not os.path.isfile(PLG):
        bad("缺少 diskrescue.plg")
        return
    text = open(PLG, encoding="utf-8").read()

    m = re.search(r"<PLUGIN\b([^>]*)>", text, re.S)
    if not m:
        bad("<PLUGIN> 元素缺失")
    else:
        attrs = re.findall(r"([\w:-]+)\s*=", m.group(1))
        dup = sorted({a for a in attrs if attrs.count(a) > 1})
        if dup:
            bad("PLUGIN 属性重复: " + ", ".join(dup))
        else:
            ok("PLUGIN 属性无重复")
        for need in ("name", "author", "version", "pluginURL"):
            if need not in attrs:
                bad("PLUGIN 缺少 %s" % need)
        if 'version="7.3"' in text or 'version="7.3"' in m.group(1):
            notes.append("已用 version 限定最低 Unraid 版本")
        ok("PLUGIN 必需属性存在")

    declared = set(re.findall(r"<!ENTITY\s+(\w+)", text))
    used = set(re.findall(r"&([A-Za-z_][\w.]*);", text)) - {"amp", "lt", "gt", "quot", "apos"}
    missing = sorted(used - declared)
    if missing:
        bad("未声明的实体: " + ", ".join(missing))
    else:
        ok("XML 实体均已声明")

    for i, block in enumerate(re.findall(r"<INLINE><!\[CDATA\[(.*?)\]\]></INLINE>", text, re.S)):
        if BASH is None:
            skip("没有 bash，跳过 INLINE 语法检查")
            break
        fd, tmp = tempfile.mkstemp(suffix=".sh")
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(block)
        try:
            p = run([BASH, "-n", tmp])
            if p.returncode != 0:
                bad("INLINE 第 %d 段语法错误: %s" % (i + 1, (p.stderr or "").strip()))
            else:
                ok("INLINE 第 %d 段 bash 语法正常" % (i + 1))
        finally:
            os.unlink(tmp)


def check_files():
    print("[2] 包内文件")
    need = [
        "DiskRescue.page", "scripts/disk-rescue.sh", "include/helpers.php",
        "include/api.php", "css/diskrescue.css", "js/diskrescue.js",
    ]
    for rel in need:
        p = os.path.join(BASE, rel)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            ok(rel)
        else:
            bad("缺失或为空: " + rel)

    for dirpath, _dirs, files in os.walk(BASE):
        for fn in files:
            if not fn.lower().endswith((".sh", ".php", ".page", ".js", ".css")):
                continue
            p = os.path.join(dirpath, fn)
            data = open(p, "rb").read()
            if b"\r" in data:
                bad("含 CRLF: " + os.path.relpath(p, BASE))


def check_syntax():
    print("[3] 脚本语法")
    if BASH:
        p = run([BASH, "-n", SCRIPT])
        if p.returncode == 0:
            ok("disk-rescue.sh: bash -n 通过")
        else:
            bad("disk-rescue.sh 语法错误:\n" + (p.stderr or ""))
    else:
        skip("没有 bash")

    if PHP:
        for rel in ("include/helpers.php", "include/api.php", "DiskRescue.page"):
            target = os.path.join(BASE, rel)
            p = run([PHP, "-l", native_arg(PHP, target)])
            out = (p.stdout + p.stderr).strip()
            if p.returncode == 0:
                ok("%s: %s" % (rel, out))
            else:
                bad("%s PHP 语法错误: %s" % (rel, out))
    else:
        skip("没有 php")

    if NODE:
        p = run([NODE, "--check", native_arg(NODE, os.path.join(BASE, "js", "diskrescue.js"))])
        if p.returncode == 0:
            ok("diskrescue.js: node --check 通过")
        else:
            bad("diskrescue.js 语法错误:\n" + (p.stderr or ""))
    else:
        skip("没有 node")


def check_functional():
    print("[4] 功能测试")
    if BASH is None:
        skip("没有 bash，跳过功能测试")
        return

    tmp = tempfile.mkdtemp(prefix="dr-test-")
    src = os.path.join(tmp, "src", "坏盘 目录")
    dst = os.path.join(tmp, "dst")
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
            full = os.path.join(src, rel)
            with open(full, "wb") as fh:
                fh.write(data)

        status = os.path.join(tmp, "status")
        log = os.path.join(tmp, "run.log")

        # --help
        p = run([BASH, SCRIPT, "--help"])
        if p.returncode == 0 and "--src" in p.stdout:
            ok("--help 输出正常")
        else:
            bad("--help 异常: rc=%d out=%r" % (p.returncode, p.stdout[:200]))

        # 缺少参数（非交互）应当失败退出，而不是卡住
        env = dict(os.environ)
        env.pop("TERM", None)
        p = run([BASH, SCRIPT], input="", env=env, timeout=20)
        if p.returncode != 0:
            ok("缺少参数时正常报错退出（rc=%d）" % p.returncode)
        else:
            bad("缺少参数时没有报错")

        # 正常复制
        p = run([BASH, SCRIPT, "--src", src, "--dst", dst, "--yes",
                 "--check", "1", "--max-stall", "3", "--min-speed", "0",
                 "--status-file", status, "--log-file", log])
        if p.returncode != 0:
            bad("复制测试失败 rc=%d\n%s\n%s" % (p.returncode, p.stdout[-1500:], p.stderr[-800:]))
        else:
            ok("复制测试 rc=0")

        for rel, data in files.items():
            got = os.path.join(dst, rel)
            if not os.path.isfile(got):
                bad("目标缺少: " + rel)
                continue
            if open(got, "rb").read() != data:
                bad("内容不一致: " + rel)
        ok("文件内容逐一比对通过")

        # status 文件
        if os.path.isfile(status):
            kv = {}
            for line in open(status, encoding="utf-8"):
                if "=" in line:
                    k, v = line.split("=", 1)
                    kv[k.strip()] = v.strip()
            for k in ("state", "phase", "total", "done", "ok", "skipped", "failed"):
                if k not in kv:
                    bad("status 缺少字段: " + k)
            if kv.get("total") == "5" and kv.get("ok") == "5" and kv.get("state") == "finished":
                ok("status 字段与计数正确 (total=5 ok=5 state=finished)")
            else:
                bad("status 计数异常: %s" % kv)
        else:
            bad("没有生成 status 文件")

        # log 里不应该有 “命令未找到”
        if os.path.isfile(log):
            txt = open(log, encoding="utf-8", errors="replace").read()
            for pat in ("command not found", "No such file or directory", "syntax error"):
                if pat in txt:
                    bad("日志中出现 %r" % pat)

        # --skip-existing：第二次运行应该全部跳过
        p = run([BASH, SCRIPT, "--src", src, "--dst", dst, "--yes", "--skip-existing",
                 "--min-speed", "0", "--check", "1", "--status-file", status, "--log-file", log])
        logtxt = open(log, encoding="utf-8", errors="replace").read() if os.path.isfile(log) else ""
        if p.returncode == 0 and "跳过" in logtxt:
            ok("--skip-existing 断点续跑正常")
        else:
            bad("--skip-existing 运行异常 rc=%d" % p.returncode)

        # 目标在源内 → 必须拒绝
        inner = os.path.join(src, "sub1", "out")
        p = run([BASH, SCRIPT, "--src", src, "--dst", inner, "--yes", "--min-speed", "0",
                 "--status-file", status, "--log-file", log])
        if p.returncode != 0 and "内部" in (p.stdout + open(log, encoding="utf-8").read()):
            ok("拒绝“目标位于源目录内部”")
        else:
            bad("没有拒绝“目标位于源目录内部” rc=%d" % p.returncode)

        # 相同路径 → 必须拒绝
        p = run([BASH, SCRIPT, "--src", src, "--dst", src, "--yes", "--min-speed", "0",
                 "--status-file", status, "--log-file", log])
        if p.returncode != 0:
            ok("拒绝“源与目标相同”")
        else:
            bad("没有拒绝“源与目标相同”")

        # --dry-run 不应复制任何文件（会建空目录并写失败清单，但不复制数据）
        dry = os.path.join(tmp, "dry")
        p = run([BASH, SCRIPT, "--src", src, "--dst", dry, "--yes", "--dry-run",
                 "--status-file", status, "--log-file", log])
        copied = []
        for dirpath, _dirs, fns in os.walk(dry):
            for fn in fns:
                if fn == "disk-rescue-failed.txt":
                    continue
                copied.append(os.path.join(dirpath, fn))
        if p.returncode == 0 and not copied:
            ok("--dry-run 未复制数据文件")
        else:
            bad("--dry-run 行为异常 rc=%d 写入=%s" % (p.returncode, copied))

    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_behavior():
    """用「慢速 dd 替身」确定性地验证卡死判定与停止流程。"""
    print("[5] 行为测试（速度判定 / 停止 / .partial）")
    if BASH is None:
        skip("没有 bash，跳过行为测试")
        return
    import signal

    tmp = tempfile.mkdtemp(prefix="dr-behav-")
    shim = os.path.join(tmp, "bin")
    os.makedirs(shim)

    dd_shim = os.path.join(shim, "dd")
    with open(dd_shim, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("""#!/bin/bash
IF=""; OF=""
for a in "$@"; do
  case "$a" in
    --help) echo "  status=progress"; exit 0 ;;
    if=*) IF="${a#if=}" ;;
    of=*) OF="${a#of=}" ;;
  esac
done
total=$(stat -c %s "$IF" 2>/dev/null || echo 0)
: > "$OF"; i=0; written=0
while [ "$written" -lt "$total" ]; do
  /bin/dd if="$IF" of="$OF" bs=1M count=1 skip="$i" seek="$i" conv=notrunc 2>/dev/null || exit 1
  written=$((written + 1048576)); i=$((i + 1))
  printf '%d bytes (1.0 MB) copied, 0.25 s, 4.2 MB/s\\n' "$written" >&2
  sleep 0.25
done
exit 0
""")
    os.chmod(dd_shim, 0o755)

    env = dict(os.environ)
    env["PATH"] = shim + os.pathsep + env.get("PATH", "")

    try:
        def scenario(tag):
            """每个场景用独立的 src/dst/log/status，避免互相污染。"""
            s = os.path.join(tmp, tag, "src")
            d = os.path.join(tmp, tag, "dst")
            os.makedirs(s)
            os.makedirs(d)
            return (s, d, os.path.join(tmp, tag, "run.log"),
                    os.path.join(tmp, tag, "status"))

        # ---- 1) 卡死判定（窗口平均速度） ----
        s1, d1, l1, st1 = scenario("stall")
        with open(os.path.join(s1, "stall.bin"), "wb") as fh:
            fh.write(b"\0" * (64 * 1024 * 1024))
        p = run([BASH, SCRIPT, "--src", s1, "--dst", d1, "--yes",
                 "--min-speed", "100", "--speed-window", "10", "--check", "1",
                 "--max-stall", "1", "--grace-factor", "0",
                 "--status-file", st1, "--log-file", l1], env=env, timeout=180)
        logtxt = open(l1, encoding="utf-8", errors="replace").read() if os.path.isfile(l1) else ""
        partial = os.path.join(d1, "stall.bin.partial")
        if p.returncode == 3:
            ok("卡死判定：退出码 3")
        else:
            bad("卡死判定：退出码 %d（期望 3）" % p.returncode)
        if os.path.isfile(partial) and os.path.getsize(partial) > 0:
            ok("卡死判定：保留了 .partial（%d 字节）" % os.path.getsize(partial))
        else:
            bad("卡死判定：没有保留 .partial")
        if "最近" in logtxt and "MB/s" in logtxt and "判定卡死" in logtxt:
            ok("卡死判定：日志给出了窗口平均速度与判定原因")
        else:
            bad("卡死判定：日志缺少窗口平均速度/判定信息")

        # ---- 2) 慢速但正常：阈值低于实际速度时必须成功，不能被窗口判定误杀 ----
        s2, d2, l2, st2 = scenario("slowok")
        with open(os.path.join(s2, "ok.bin"), "wb") as fh:
            fh.write(b"\0" * (48 * 1024 * 1024))
        p = run([BASH, SCRIPT, "--src", s2, "--dst", d2, "--yes",
                 "--min-speed", "1", "--speed-window", "10", "--check", "1",
                 "--max-stall", "1", "--grace-factor", "0",
                 "--status-file", st2, "--log-file", l2], env=env, timeout=180)
        logtxt = open(l2, encoding="utf-8", errors="replace").read() if os.path.isfile(l2) else ""
        target = os.path.join(d2, "ok.bin")
        if p.returncode == 0 and os.path.isfile(target) and \
                os.path.getsize(target) == 48 * 1024 * 1024:
            ok("慢速正常文件：复制成功且未被误杀")
        else:
            bad("慢速正常文件：rc=%d 大小=%s" % (
                p.returncode, os.path.getsize(target) if os.path.isfile(target) else "缺失"))
        if "判定卡死" not in logtxt:
            ok("慢速正常文件：日志中没有误判")
        else:
            bad("慢速正常文件：被误判为卡死")

        # ---- 3) 停止流程 ----
        s3, d3, l3, st3 = scenario("stop")
        with open(os.path.join(s3, "stop.bin"), "wb") as fh:
            fh.write(b"\0" * (32 * 1024 * 1024))
        proc = subprocess.Popen(
            [BASH, SCRIPT, "--src", s3, "--dst", d3, "--yes", "--min-speed", "0",
             "--check", "1", "--max-stall", "3",
             "--status-file", st3, "--log-file", l3],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(5)
        proc.send_signal(signal.SIGTERM)
        try:
            rc = proc.wait(timeout=40)
        except subprocess.TimeoutExpired:
            proc.kill()
            rc = -1
        stxt = open(st3, encoding="utf-8", errors="replace").read() if os.path.isfile(st3) else ""
        partial2 = os.path.join(d3, "stop.bin.partial")
        if rc == 2:
            ok("停止流程：退出码 2")
        else:
            bad("停止流程：退出码 %d（期望 2）" % rc)
        if "state=stopped" in stxt:
            ok("停止流程：state=stopped")
        else:
            bad("停止流程：state 不是 stopped")
        if os.path.isfile(partial2) and os.path.getsize(partial2) > 0:
            ok("停止流程：保留了 .partial（%d 字节）" % os.path.getsize(partial2))
        else:
            bad("停止流程：没有保留 .partial")
        leftovers = [f for f in os.listdir(d3) if ".dr-meta." in f]
        if leftovers:
            bad("停止流程：残留临时文件 %s" % leftovers)
        else:
            ok("停止流程：无 .dr-meta 残留")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    print("== diskrescue 静态检查与功能测试 ==\n")
    check_plg()
    check_files()
    check_syntax()
    check_functional()
    check_behavior()

    print("\n== 结果 ==")
    if notes:
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
