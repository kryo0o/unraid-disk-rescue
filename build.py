#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build.py - 打包 Unraid 插件（不需要系统安装 tar / xz）

用法:
    python build.py                  # 生成 dist/ 下的 .txz 与 .plg
    python build.py --check          # 只做静态检查
    python build.py --base-url URL   # 指定安装包公网地址前缀

产物:
    dist/diskrescue-<version>.txz          插件包（根目录为 usr/，tar.xz 格式）
    dist/diskrescue-<version>.txz.sha256
    dist/diskrescue.plg                    可直接安装的插件清单（已写入 MD5）

生成的 .txz 使用 POSIX tar + xz 压缩，Unraid 上 `tar -xJf` 可直接解压，
目录项带有 0755 权限、文件项 0644/0755，解压后无需再修正权限。
"""

import argparse
import hashlib
import io
import os
import re
import sys
import tarfile
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
PKG_SRC = os.path.join(ROOT, "package")
DIST = os.path.join(ROOT, "dist")
PLG_TEMPLATE = os.path.join(ROOT, "diskrescue.plg.in")

VERSION = "2026.11.12"
PLUGIN = "diskrescue"
PKG_NAME = "%s-%s.txz" % (PLUGIN, VERSION)
DEFAULT_BASE = "https://blog.kryoo.de/unraid-disk-rescue"

TEXT_EXT = (".sh", ".php", ".page", ".js", ".css", ".md", ".txt", ".plg", ".cfg")
EXECUTABLES = {
    "usr/local/emhttp/plugins/diskrescue/scripts/disk-rescue.sh": 0o755,
}
# 不参与打包（仅源码仓库使用）
EXCLUDE_REL = {
    "usr/local/emhttp/plugins/diskrescue/include/install.sh",
    "usr/local/emhttp/plugins/diskrescue/include/uninstall.sh",
    "usr/local/emhttp/plugins/diskrescue/.encoding",
}


def info(msg):
    print("[build] " + msg)


def die(msg):
    print("[build] 错误: " + msg, file=sys.stderr)
    sys.exit(1)


def walk_files(base):
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for fn in sorted(filenames):
            yield os.path.join(dirpath, fn)


# --------------------------------------------------------------------------
#  静态检查
# --------------------------------------------------------------------------
def find_bash():
    from shutil import which
    for cand in ("bash", "bash.exe"):
        p = which(cand)
        if p:
            return p
    for cand in (r"C:\Program Files\Git\bin\bash.exe",
                 r"C:\Program Files\Git\usr\bin\bash.exe",
                 "/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash"):
        if os.path.isfile(cand):
            return cand
    return None


def bash_syntax_check(script=None, path=None):
    bash = find_bash()
    if not bash:
        return None
    import subprocess
    import tempfile
    if path:
        proc = subprocess.run([bash, "-n", path], capture_output=True, text=True)
        return None if proc.returncode == 0 else (proc.stderr or "").strip()
    fd, tmp = tempfile.mkstemp(suffix=".sh")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(script)
        proc = subprocess.run([bash, "-n", tmp], capture_output=True, text=True)
        return None if proc.returncode == 0 else (proc.stderr or "").strip()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def find_php():
    env = os.environ.get("PHP")
    if env and (os.path.isfile(env) or __import__("shutil").which(env)):
        return env
    from shutil import which
    for cand in ("php", "php.exe"):
        p = which(cand)
        if p:
            return p
    for cand in (r"C:\php\php.exe", "/usr/bin/php", "/usr/local/bin/php"):
        if os.path.isfile(cand):
            return cand
    return None


def check_plg_structure(text):
    """.plg 的轻量 XML 检查（不依赖 DOCTYPE 实体解析）。"""
    problems = []
    m = re.search(r"<PLUGIN\b([^>]*)>", text, re.S)
    if not m:
        problems.append(".plg 缺少 <PLUGIN> 元素")
        return problems
    attr_text = m.group(1)
    attrs = re.findall(r"([\w:-]+)\s*=", attr_text)
    dup = sorted({a for a in attrs if attrs.count(a) > 1})
    if dup:
        problems.append("PLUGIN 属性重复: " + ", ".join(dup))
    for need in ("name", "author", "version", "pluginURL"):
        if need not in attrs:
            problems.append("PLUGIN 缺少 %s 属性" % need)
    if re.search(r"</?PLUGIN\b", text) is None:
        problems.append(".plg 缺少 PLUGIN 闭合标签")
    return problems


def check_entities(text):
    declared = set(re.findall(r"<!ENTITY\s+(\w+)", text))
    used = set(re.findall(r"&([A-Za-z_][\w.]*);", text))
    used -= {"amp", "lt", "gt", "quot", "apos"}
    missing = sorted(used - declared)
    return [] if not missing else ["未声明的 XML 实体: " + ", ".join(missing)]


def check_xml_wellformed(text):
    """把 DOCTYPE/实体展开后做一次真正的 XML 解析，确认 .plg 格式合法。"""
    import xml.etree.ElementTree as ET

    entities = dict(re.findall(r'<!ENTITY\s+(\w+)\s+"([^"]*)"', text))
    body = re.sub(r"<!DOCTYPE.*?\]>", "", text, flags=re.S)
    # 迭代展开实体引用
    for _ in range(5):
        changed = False
        for k, v in entities.items():
            token = "&%s;" % k
            if token in body:
                body = body.replace(token, v)
                changed = True
        if not changed:
            break
    body = re.sub(r"<\?xml[^>]*\?>", "", body).strip()
    try:
        root = ET.fromstring(body)
    except ET.ParseError as exc:
        return ["`.plg` 不是合法 XML: %s" % exc]
    if root.tag != "PLUGIN":
        return ["`.plg` 根元素应为 PLUGIN，实际是 %s" % root.tag]
    files = root.findall("FILE")
    runs = [f for f in files if f.get("Run")]
    named = [f for f in files if f.get("Name")]
    problems = []
    if not runs:
        problems.append("`.plg` 缺少安装/卸载的 <FILE Run=...> 片段")
    if not named:
        problems.append("`.plg` 缺少下载安装包的 <FILE Name=...> 片段")
    return problems


def run_check():
    problems = []

    if not os.path.isfile(PLG_TEMPLATE):
        die("找不到 .plg 模板: " + PLG_TEMPLATE)
    with open(PLG_TEMPLATE, "r", encoding="utf-8") as fh:
        text = fh.read()

    problems += check_plg_structure(text)
    problems += check_entities(text)
    problems += check_xml_wellformed(text)

    for i, block in enumerate(re.findall(r"<INLINE><!\[CDATA\[(.*?)\]\]></INLINE>", text, re.S)):
        err = bash_syntax_check(script=block)
        if err:
            problems.append("INLINE 第 %d 段 bash 语法错误:\n      %s" % (i + 1, err))

    base = os.path.join(PKG_SRC, "usr/local/emhttp/plugins/diskrescue")
    required = [
        "DiskRescue.page",
        "scripts/disk-rescue.sh",
        "include/helpers.php",
        "include/api.php",
        "css/diskrescue.css",
        "js/diskrescue.js",
    ]
    for rel in required:
        if not os.path.isfile(os.path.join(base, rel)):
            problems.append("缺少文件: " + rel)

    sh = os.path.join(base, "scripts/disk-rescue.sh")
    if os.path.isfile(sh):
        err = bash_syntax_check(path=sh)
        if err:
            problems.append("disk-rescue.sh 语法错误:\n      " + err)

    # PHP 标签配对兜底检查（没有 php 可执行文件时）。
    # 注意：纯 PHP 文件允许省略结尾的 ?>，所以不能简单比较开闭数量。
    # 这里只检查 .page —— 它后面跟着 HTML，每个 <?= ... 必须在 HTML 之前闭合。
    page = os.path.join(base, "DiskRescue.page")
    if os.path.isfile(page):
        src = open(page, encoding="utf-8", errors="replace").read()
        if "\n---\n" in src:
            src = src.split("\n---\n", 1)[1]
        opens = len(re.findall(r"<\?(?:php|=)", src))
        closes = src.count("?>")
        if closes > opens:
            problems.append("DiskRescue.page 的 PHP 标签不配对（<? %d 个 / ?> %d 个）" % (opens, closes))
        # 每个 <?= 后面必须紧跟 ?>，否则会把 HTML 吞进表达式
        for m in re.finditer(r"<\?=", src):
            if src.find("?>", m.end()) == -1:
                problems.append("DiskRescue.page 存在未闭合的 <?= 表达式")
                break

    for path in walk_files(PKG_SRC):
        if path.lower().endswith(TEXT_EXT) and not path.endswith(".png"):
            with open(path, "rb") as fh:
                if b"\r" in fh.read():
                    problems.append("文件包含 CRLF: " + os.path.relpath(path, PKG_SRC))

    php = find_php()
    if php:
        import subprocess
        for rel in ("include/helpers.php", "include/api.php", "DiskRescue.page"):
            path = os.path.join(base, rel)
            if not os.path.isfile(path):
                continue
            proc = subprocess.run([php, "-l", path], capture_output=True, text=True)
            if proc.returncode != 0:
                problems.append("PHP 语法错误 %s: %s" % (rel, (proc.stdout + proc.stderr).strip()))
    else:
        info("未找到 php，跳过 PHP 语法检查")

    if problems:
        print("[check] 发现 %d 个问题:" % len(problems))
        for p in problems:
            print("   - " + p)
        return False

    print("[check] 所有检查通过")
    return True


# --------------------------------------------------------------------------
#  打包
# --------------------------------------------------------------------------
def fix_line_endings(base):
    changed = 0
    for path in walk_files(base):
        if not path.lower().endswith(TEXT_EXT):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        if b"\r" in data:
            data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
            with open(path, "wb") as fh:
                fh.write(data)
            changed += 1
    if changed:
        info("已把 %d 个文本文件的换行转换为 LF" % changed)


def ensure_icon():
    """图标缺失时尝试生成；再不行就写一个纯色占位图标，保证 .plg 的 icon 不 404。"""
    target = os.path.join(PKG_SRC, "usr", "local", "emhttp", "plugins", "diskrescue",
                          "icons", "diskrescue.png")
    repo_icon = os.path.join(ROOT, "icons", "diskrescue.png")
    if os.path.isfile(target) and os.path.getsize(target) > 0:
        return

    gen = os.path.join(ROOT, "tools", "make_icon.py")
    if os.path.isfile(gen):
        try:
            import subprocess
            subprocess.run([sys.executable, gen], check=True)
            info("已调用 tools/make_icon.py 生成图标")
            if os.path.isfile(target):
                return
        except Exception as exc:  # noqa: BLE001
            info("自动生成图标失败: %s" % exc)

    # 兜底：48x48 纯色 PNG
    import struct
    import zlib
    w = h = 48
    raw = b"".join(b"\x00" + bytes((34, 112, 192, 255)) * w for _ in range(h))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(raw, 9)) +
           chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    os.makedirs(os.path.dirname(repo_icon), exist_ok=True)
    with open(target, "wb") as fh:
        fh.write(png)
    with open(repo_icon, "wb") as fh:
        fh.write(png)
    info("已写入占位图标")


def build_package():
    if not os.path.isdir(PKG_SRC):
        die("找不到 package 目录: " + PKG_SRC)
    os.makedirs(DIST, exist_ok=True)
    ensure_icon()
    fix_line_endings(PKG_SRC)

    out = os.path.join(DIST, PKG_NAME)

    with tarfile.open(out, "w:xz", format=tarfile.GNU_FORMAT, preset=6) as tar:
        for dirpath, dirnames, filenames in os.walk(PKG_SRC):
            dirnames.sort()
            rel_dir = os.path.relpath(dirpath, PKG_SRC).replace("\\", "/")
            if rel_dir != ".":
                ti = tarfile.TarInfo(rel_dir)
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                ti.uid = 0
                ti.gid = 0
                ti.uname = "root"
                ti.gname = "root"
                ti.mtime = int(time.time())
                tar.addfile(ti)

            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, PKG_SRC).replace("\\", "/")
                if rel in EXCLUDE_REL:
                    continue
                with open(full, "rb") as fh:
                    data = fh.read()
                ti = tarfile.TarInfo(rel)
                ti.size = len(data)
                ti.mode = EXECUTABLES.get(rel, 0o644)
                ti.uid = 0
                ti.gid = 0
                ti.uname = "root"
                ti.gname = "root"
                ti.mtime = int(time.time())
                ti.type = tarfile.REGTYPE
                tar.addfile(ti, io.BytesIO(data))

    # 自检：能重新读出来、条目数正确
    with tarfile.open(out, "r:xz") as tar:
        names = tar.getnames()
    if not any(n.endswith("scripts/disk-rescue.sh") for n in names):
        die("打包自检失败：安装包里没有 disk-rescue.sh")

    info("已生成 %s（%.1f KB，%d 个条目）" % (out, os.path.getsize(out) / 1024.0, len(names)))
    return out, names


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def build_plg(package_path, base_url, local=False):
    with open(PLG_TEMPLATE, "r", encoding="utf-8") as fh:
        text = fh.read()

    if local:
        # 离线安装：安装包已放在 /boot/config/plugins/diskrescue/package.txz
        pkg_url = "file:///boot/config/plugins/%s/package.txz" % PLUGIN
        out_name = "%s-local.plg" % PLUGIN
    else:
        base_url = base_url.rstrip("/")
        pkg_url = "%s/dist/%s" % (base_url, PKG_NAME)
        out_name = "%s.plg" % PLUGIN

    md5 = md5_of(package_path)

    text = re.sub(r'<!ENTITY\s+pkgURL\s+"[^"]*">',
                  '<!ENTITY pkgURL    "%s">' % pkg_url, text)
    text = text.replace("__MD5__", md5)
    text = text.replace("__PKGURL__", pkg_url)
    if not local:
        # 清单自身的地址要指向 dist/ 里的成品，而不是仓库根目录的模板
        text = re.sub(r'<!ENTITY\s+pluginURL\s+"[^"]*">',
                      '<!ENTITY pluginURL "%s/dist/%s.plg">' % (base_url, PLUGIN), text)
        text = re.sub(r'<!ENTITY\s+gitURL\s+"[^"]*">',
                      '<!ENTITY gitURL "%s">' % base_url, text)
    else:
        # 离线包：清单/图标/安装包都指向本机固定位置
        text = text.replace("&gitURL;/icons/diskrescue.png",
                            "/plugins/%s/icons/diskrescue.png" % PLUGIN)
        text = re.sub(r'<!ENTITY\s+pluginURL\s+"[^"]*">',
                      '<!ENTITY pluginURL "file:///boot/config/plugins/%s.plg">' % PLUGIN,
                      text)

    if "__MD5__" in text or "__PKGURL__" in text:
        die("替换占位符失败，请检查 .plg 模板")

    out = os.path.join(DIST, out_name)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    info("已生成 %s（MD5 %s）" % (out, md5))
    if not local and "your-github-user" in base_url:
        print("[build] 注意: 仍在使用占位仓库地址，只能本地安装；")
        print("[build]       发布前请用 --base-url https://raw.githubusercontent.com/<你>/<仓库>/main")
    return out


def main():
    ap = argparse.ArgumentParser(description="打包 Unraid 插件")
    ap.add_argument("--check", action="store_true", help="只做静态检查")
    ap.add_argument("--base-url", default=DEFAULT_BASE, help="安装包公网地址前缀")
    args = ap.parse_args()

    if args.check:
        sys.exit(0 if run_check() else 1)

    ok = run_check()
    if not ok:
        print("[build] 警告: 静态检查未通过，仍尝试打包（仅建议本地测试）")
        time.sleep(1)

    pkg, _ = build_package()
    plg = build_plg(pkg, args.base_url)
    local_plg = build_plg(pkg, args.base_url, local=True)
    digest = sha256_of(pkg)
    with open(pkg + ".sha256", "w", encoding="ascii", newline="\n") as fh:
        fh.write("%s  %s\n" % (digest, os.path.basename(pkg)))
    info("SHA256: " + digest)
    info("完成: %s  %s  %s" % (pkg, plg, local_plg))


if __name__ == "__main__":
    main()
