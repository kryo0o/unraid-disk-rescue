<?php
/**
 * diskrescue 容器入口
 *
 * 复用 Unraid 插件的页面主体（include/page-body.php），
 * 只把路径改成容器布局：
 *   /opt/diskrescue  -> 插件目录（DR_BASE）
 *   /data            -> 配置与日志（DR_DATA_DIR）
 */

$root = getenv('DR_APP_ROOT') ?: '/opt/diskrescue';

putenv('DR_BASE=' . $root);
putenv('DR_DATA_DIR=' . (getenv('DR_DATA_DIR') ?: '/data'));
putenv('DR_TMP=' . (getenv('DR_TMP') ?: '/tmp/diskrescue'));
putenv('DR_ASSET_BASE=');
putenv('DR_API_URL=/api.php');

// 主目录路径（/mnt/disk1 等）由挂载决定，插件侧的校验仍然只允许 /mnt
require $root . '/include/page-body.php';
