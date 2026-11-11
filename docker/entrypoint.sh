#!/bin/sh
# diskrescue 容器启动脚本
#   - 准备 /data 与 /tmp
#   - 可选 HTTP Basic 认证（DR_USER / DR_PASS）
#   - 交给 apache2-foreground
set -e

DATA_DIR="${DR_DATA_DIR:-/data}"
RUN_USER="${APACHE_RUN_USER:-root}"
RUN_GROUP="${APACHE_RUN_GROUP:-root}"

mkdir -p "$DATA_DIR/state" /tmp/diskrescue
chmod 755 "$DATA_DIR" 2>/dev/null || true

# 可选：基础认证（强烈建议在非纯内网环境启用）
if [ -n "${DR_USER:-}" ] && [ -n "${DR_PASS:-}" ]; then
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -bc /etc/apache2/.htpasswd "$DR_USER" "$DR_PASS" >/dev/null 2>&1
    else
        printf '%s:%s\n' "$DR_USER" "$(openssl passwd -apr1 "$DR_PASS")" > /etc/apache2/.htpasswd
    fi
    cat > /etc/apache2/conf-enabled/zz-diskrescue-auth.conf <<EOF
<Directory /var/www/html>
    AuthType Basic
    AuthName "Disk Rescue"
    AuthUserFile /etc/apache2/.htpasswd
    Require valid-user
</Directory>
EOF
    echo "[diskrescue] 已启用 Basic 认证（用户: $DR_USER）"
fi

# 容器内以 root 运行，才能像在 Unraid 上一样读写 /mnt/diskX
chown -R "$RUN_USER:$RUN_GROUP" "$DATA_DIR" 2>/dev/null || true

echo "[diskrescue] data=$DATA_DIR user=$RUN_USER"
echo "[diskrescue] 打开 http://<主机IP>:<映射端口>/ 使用"

exec "$@"
