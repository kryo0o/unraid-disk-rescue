#!/bin/sh
# diskrescue 容器启动脚本
#   - 准备 /data 与 /tmp
#   - 生成 nginx server 配置（可选 Basic 认证）
#   - 启动 php-fpm(-R) 与 nginx
set -e

DATA_DIR="${DR_DATA_DIR:-/data}"

mkdir -p "$DATA_DIR/state" /tmp/diskrescue
chmod 755 "$DATA_DIR" 2>/dev/null || true

AUTH=""
if [ -n "${DR_USER:-}" ] && [ -n "${DR_PASS:-}" ]; then
    printf '%s:%s\n' "$DR_USER" "$(openssl passwd -apr1 "$DR_PASS")" > /etc/nginx/.htpasswd
    chmod 640 /etc/nginx/.htpasswd
    AUTH='auth_basic "Disk Rescue";
        auth_basic_user_file /etc/nginx/.htpasswd;'
    echo "[diskrescue] 已启用 Basic 认证（用户: $DR_USER）"
fi

cat > /etc/nginx/conf.d/diskrescue.conf <<EOF
server {
    listen 80;
    root /var/www/html;
    index index.php;
    ${AUTH}

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\. {
        deny all;
    }

    location = /favicon.ico {
        access_log off;
        return 204;
    }
}
EOF

# php-fpm 以 root 运行（-R）；-D 后台启动
php-fpm -R -D

echo "[diskrescue] data=$DATA_DIR"
echo "[diskrescue] 打开 http://<主机IP>:<映射端口>/ 使用"

exec "$@"
