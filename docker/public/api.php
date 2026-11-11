<?php
/**
 * diskrescue 容器 AJAX 接口
 *
 * 与 Unraid 插件共用 include/api.php，只负责设置容器内的路径。
 */

$root = getenv('DR_APP_ROOT') ?: '/opt/diskrescue';

putenv('DR_BASE=' . $root);
putenv('DR_DATA_DIR=' . (getenv('DR_DATA_DIR') ?: '/data'));
putenv('DR_TMP=' . (getenv('DR_TMP') ?: '/tmp/diskrescue'));

require $root . '/include/api.php';
