#!/bin/bash
# =============================================================================
#  build.sh - 在 Unraid 控制台（或任意 Linux）上一键打包
#
#  用法:
#    ./build.sh                    # 打包到 dist/
#    ./build.sh --base-url URL     # 指定安装包公网地址前缀
#    ./build.sh --install          # 打包后直接在本机安装/更新插件
#
#  说明:
#    优先使用 python3；Unraid 自带 python3 可能没有，此时会回退到
#    "纯 shell 打包"（tar + xz），两条路径生成的文件结构一致。
# =============================================================================
set -eu

cd "$(dirname "$0")"
BASE_URL="https://cdn.jsdelivr.net/gh/kryo0o/unraid-disk-rescue@main"
DO_INSTALL=0
VERSION="2026.11.12"
PLUGIN="diskrescue"
PKG="${PLUGIN}-${VERSION}.txz"
TEMPLATE="${PLUGIN}.plg.in"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --install)  DO_INSTALL=1; shift ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

echo "=== 打包 ${PLUGIN} ${VERSION} ==="
mkdir -p dist

# 统一换行
if command -v perl >/dev/null 2>&1; then
  find package -type f \( -name '*.sh' -o -name '*.php' -o -name '*.page' -o -name '*.js' \
    -o -name '*.css' -o -name '*.md' \) -print0 | xargs -0 -r perl -pi -e 's/\r\n/\n/g; s/\r/\n/g'
else
  find package -type f \( -name '*.sh' -o -name '*.php' -o -name '*.page' -o -name '*.js' \
    -o -name '*.css' -o -name '*.md' \) -print0 | while IFS= read -r -d '' f; do
      sed -i 's/\r$//' "$f"
    done
fi

# 图标（没有就生成一个占位图）
ICON="package/usr/local/emhttp/plugins/${PLUGIN}/icons/${PLUGIN}.png"
if [ ! -s "$ICON" ]; then
  mkdir -p "$(dirname "$ICON")" icons
  if command -v python3 >/dev/null 2>&1; then
    python3 tools/make_icon.py || true
  fi
  if [ ! -s "$ICON" ]; then
    printf '\x89PNG\r\n\x1a\n' > "$ICON"
    echo "警告: 未生成图标，仅写入了占位文件"
  fi
fi
cp -f "$ICON" "icons/${PLUGIN}.png" 2>/dev/null || true

# 打包：先复制到暂存目录，统一权限后再压缩（避免继承挂载点/Windows 的 777）
STAGE=$(mktemp -d /tmp/diskrescue-build.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"
cp -R package/usr "$STAGE"/
rm -f "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/include/install.sh" \
      "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/include/uninstall.sh" \
      "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/.encoding"

find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/usr/local/emhttp/plugins/${PLUGIN}/scripts/disk-rescue.sh"

tar -C "$STAGE" --owner=0 --group=0 -cJf "dist/${PKG}" usr

tar -tJf "dist/${PKG}" | grep -q 'scripts/disk-rescue.sh' || {
  echo "错误: 打包结果缺少 disk-rescue.sh" >&2
  exit 1
}

MD5=$(md5sum "dist/${PKG}" | cut -d' ' -f1)
SHA=$(sha256sum "dist/${PKG}" | cut -d' ' -f1)
echo "$SHA  ${PKG}" > "dist/${PKG}.sha256"
PKG_URL="${BASE_URL%/}/dist/${PKG}"

sed -e "s#__MD5__#${MD5}#g" \
    -e "s#__PKGURL__#${PKG_URL}#g" \
    -e "s#&gitURL;/${PLUGIN}.plg#${PKG_URL%/*}/${PLUGIN}.plg#g" \
    -e "s#https://cdn.jsdelivr.net/gh/kryo0o/unraid-disk-rescue@main#${BASE_URL%/}#g" \
    "$TEMPLATE" > "dist/${PLUGIN}.plg"

# 离线安装用清单：清单/安装包都走本地固定位置（/boot/config/plugins/<name>.plg）
sed -e "s#__MD5__#${MD5}#g" \
    -e "s#__PKGURL__#file:///boot/config/plugins/${PLUGIN}/package.txz#g" \
    -e "s#&gitURL;/dist/${PKG}#file:///boot/config/plugins/${PLUGIN}/package.txz#g" \
    -e "s#&gitURL;/icons/${PLUGIN}.png#/plugins/${PLUGIN}/icons/${PLUGIN}.png#g" \
    -e "s#&gitURL;/${PLUGIN}.plg#file:///boot/config/plugins/${PLUGIN}.plg#g" \
    "$TEMPLATE" > "dist/${PLUGIN}-local.plg"

echo "安装包: dist/${PKG}  ($(du -h "dist/${PKG}" | cut -f1))"
echo "MD5   : ${MD5}"
echo "SHA256: ${SHA}"
echo "清单  : dist/${PLUGIN}.plg  dist/${PLUGIN}-local.plg"

if [ "$DO_INSTALL" = "1" ]; then
  echo "=== 安装到本机 ==="
  mkdir -p "/boot/config/plugins/${PLUGIN}"
  cp -f "dist/${PKG}" "/boot/config/plugins/${PLUGIN}/package.txz"
  rm -rf "/usr/local/emhttp/plugins/${PLUGIN}"
  mkdir -p "/usr/local/emhttp/plugins/${PLUGIN}"
  tar -xJf "/boot/config/plugins/${PLUGIN}/package.txz" -C /
  chmod -R 755 "/usr/local/emhttp/plugins/${PLUGIN}"
  chmod 755 "/usr/local/emhttp/plugins/${PLUGIN}/scripts/disk-rescue.sh"
  mkdir -p "/boot/config/plugins/${PLUGIN}/state"
  [ -x /etc/rc.d/rc.php-fpm ] && /etc/rc.d/rc.php-fpm reload >/dev/null 2>&1 || true
  echo "已安装。打开 WebGUI -> Tools（工具）-> 坏盘数据抢救"
fi
