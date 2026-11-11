# syntax=docker/dockerfile:1
#
# diskrescue - 坏盘数据抢救（Web UI）
#
#   docker build -t diskrescue .
#   docker run -d --name diskrescue -p 8080:80 \
#     -v /mnt:/mnt -v /srv/diskrescue:/data diskrescue
#
FROM php:8.4-apache

ENV TZ=Asia/Shanghai \
    DR_DATA_DIR=/data \
    DR_CSRF_TOKEN="" \
    APACHE_RUN_USER=root \
    APACHE_RUN_GROUP=root

# 运行抢救脚本需要的工具（dd/cp/stat/find/timeout/setsid 等大多已有）
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl procps util-linux apache2-utils \
 && rm -rf /var/lib/apt/lists/*

# 插件本体：页面、接口、脚本
COPY package/usr/local/emhttp/plugins/diskrescue /opt/diskrescue

# Web 根目录：入口 + 静态资源
COPY docker/public /var/www/html
RUN cp -R /opt/diskrescue/css /opt/diskrescue/js /opt/diskrescue/icons /var/www/html/ \
 && chmod 755 /opt/diskrescue/scripts/disk-rescue.sh \
 && printf 'User root\nGroup root\n' > /etc/apache2/conf-enabled/zz-runas.conf \
 && a2enmod headers >/dev/null 2>&1 || true

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 容器内的抢救脚本输出是给人看的，保留中文
ENV LANG=C.UTF-8

EXPOSE 80

# Basic 认证开启时返回 401 也算“活着”
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ | grep -qE "^(200|301|302|401)$"'

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]
