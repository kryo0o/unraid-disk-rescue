#!/bin/bash
# =============================================================================
#  install-local.sh - 命令行安装 / 卸载 diskrescue
#
#  用法（Unraid 控制台，root）:
#    bash tools/install-local.sh              # 安装（持久化，重启后仍在）
#    bash tools/install-local.sh --uninstall  # 卸载
#
#  做的事情:
#    1. 把插件打包成 /boot/config/plugins/diskrescue/package.txz
#    2. 生成离线清单 /boot/config/plugins/diskrescue.plg（含 MD5）
#    3. 优先用 /usr/local/sbin/plugin install 注册安装；
#       没有该命令时退化为手工解压（同样会留下 plg，重启后由 Unraid 重装）
# =============================================================================
set -eu

PLUGIN="diskrescue"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/package/usr/local/emhttp/plugins/${PLUGIN}"
DEST="/usr/local/emhttp/plugins/${PLUGIN}"
BOOT="/boot/config/plugins"
PKGDIR="${BOOT}/${PLUGIN}"
PLG="${BOOT}/${PLUGIN}.plg"
TEMPLATE="$ROOT/${PLUGIN}.plg.in"

if [ "${1:-}" = "--uninstall" ]; then
    echo "卸载 ${PLUGIN} ..."
    if [ -x /usr/local/sbin/plugin ]; then
        /usr/local/sbin/plugin remove "$PLUGIN" 2>/dev/null || true
    fi
    rm -rf "$DEST" "$PKGDIR" "$PLG"
    [ -x /etc/rc.d/rc.php-fpm ] && /etc/rc.d/rc.php-fpm reload >/dev/null 2>&1 || true
    echo "已卸载（目标磁盘上已复制的数据不受影响）。"
    exit 0
fi

if [ "$(id -u)" != "0" ]; then
    echo "请用 root 运行（Unraid 控制台默认就是 root）" >&2
    exit 1
fi
if [ ! -d "$SRC" ]; then
    echo "错误: 找不到源码目录 $SRC" >&2
    exit 1
fi
if ! command -v tar >/dev/null 2>&1; then
    echo "错误: 缺少 tar" >&2
    exit 1
fi

echo "== 1/3 打包 =="
STAGE=$(mktemp -d /tmp/dr-install.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"
cp -R "$ROOT/package/usr" "$STAGE"/
rm -f "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/include/install.sh" \
      "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/include/uninstall.sh" \
      "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/.encoding"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/scripts/disk-rescue.sh"

mkdir -p "$PKGDIR" "$BOOT"
tar -C "$STAGE" --owner=0 --group=0 -cJf "${PKGDIR}/package.txz" usr
MD5=$(md5sum "${PKGDIR}/package.txz" | cut -d' ' -f1)
echo "   package.txz  MD5=${MD5}"

echo "== 2/3 生成离线清单 =="
sed -e "s#__MD5__#${MD5}#g" \
    -e "s#__PKGURL__#file://${PKGDIR}/package.txz#g" \
    -e "s#&gitURL;/dist/[^\"<]*#file://${PKGDIR}/package.txz#g" \
    -e "s#&gitURL;/icons/${PLUGIN}.png#/plugins/${PLUGIN}/icons/${PLUGIN}.png#g" \
    -e "s#&gitURL;/${PLUGIN}.plg#file://${PLG}#g" \
    "$TEMPLATE" > "$PLG"
grep -q '__MD5__\|__PKGURL__' "$PLG" && { echo "错误: 清单占位符未替换" >&2; exit 1; }

echo "== 3/3 安装 =="
if [ -x /usr/local/sbin/plugin ]; then
    /usr/local/sbin/plugin install "$PLG"
else
    echo "   未找到 /usr/local/sbin/plugin，改为手工解压"
    rm -rf "$DEST"
    mkdir -p "$DEST"
    tar -xJf "${PKGDIR}/package.txz" -C /
    chmod -R 755 "$DEST"
    chmod 755 "$DEST/scripts/disk-rescue.sh"
    [ -x /etc/rc.d/rc.php-fpm ] && /etc/rc.d/rc.php-fpm reload >/dev/null 2>&1 || true
fi

if [ -f "$DEST/scripts/disk-rescue.sh" ]; then
    bash -n "$DEST/scripts/disk-rescue.sh" || { echo "脚本语法错误" >&2; exit 1; }
fi

echo
echo "安装完成。刷新 WebGUI，打开 Tools（工具）-> 坏盘数据抢救"
echo "卸载: bash tools/install-local.sh --uninstall"
