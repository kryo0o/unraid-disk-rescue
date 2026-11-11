# syntax=docker/dockerfile:1
#
# diskrescue - 坏盘数据抢救（Web UI）
#
#   docker build -f docker/Dockerfile -t diskrescue .
#   docker run -d --name diskrescue -p 8080:80 \
#     -v /mnt:/mnt -v /srv/diskrescue:/data diskrescue
#
# 用 nginx + php-fpm(-R) 而不是 Apache：Apache 拒绝以 root 运行，
# 而抢救脚本需要 root 才能读写 /mnt/diskX。
#
FROM php:8.4-fpm

ENV TZ=Asia/Shanghai \
    DR_DATA_DIR=/data \
    DR_CSRF_TOKEN="" \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx curl procps util-linux openssl \
 && rm -rf /var/lib/apt/lists/*

# 应用本体：页面、接口、脚本
COPY app /opt/diskrescue

# Web 根目录：入口 + 静态资源
COPY docker/public /var/www/html
RUN cp -R /opt/diskrescue/css /opt/diskrescue/js /var/www/html/ \
 && chmod 755 /opt/diskrescue/scripts/disk-rescue.sh

# nginx 主配置与 php-fpm 的 root 池
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/php-fpm-root.conf /usr/local/etc/php-fpm.d/zz-root.conf

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80

# Basic 认证开启时返回 401 也算“活着”
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ | grep -qE "^(200|301|302|401)$"'

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
