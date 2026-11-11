<?php
/**
 * diskrescue 插件公共函数
 *
 * Unraid 的 .page / .php 都是被 webGUI 直接 include 执行的，本文件只做函数定义，
 * 不产生任何直接输出。页面与接口统一通过 require_once 引入。
 */

define('DR_PLUGIN', 'diskrescue');
// 路径都可用环境变量覆盖：插件用默认值，Docker 容器用 /opt 与 /data
define('DR_BASE', getenv('DR_BASE') ?: '/usr/local/emhttp/plugins/diskrescue');
define('DR_BOOT', getenv('DR_DATA_DIR') ?: '/boot/config/plugins/diskrescue');
define('DR_STATE', DR_BOOT . '/state');
define('DR_TMP', getenv('DR_TMP') ?: '/tmp/diskrescue');
define('DR_RUNNING', DR_TMP . '/running');
define('DR_CFG', DR_BOOT . '/diskrescue.cfg');

/** 静态资源前缀：插件里是 /plugins/diskrescue，容器里是空（同源根路径） */
function dr_asset_base() {
    $v = getenv('DR_ASSET_BASE');
    if ($v === false) {
        return '/plugins/' . DR_PLUGIN;
    }
    return rtrim($v, '/');
}

/** AJAX 接口地址：插件里是 <asset>/include/api.php，容器里是 /api.php */
function dr_api_url() {
    $v = getenv('DR_API_URL');
    if ($v !== false && $v !== '') {
        return $v;
    }
    return dr_asset_base() . '/include/api.php';
}

/** 配置/日志目录（页面上展示用） */
function dr_data_dir() {
    return DR_BOOT;
}

/**
 * 在 webGUI（php-fpm）里 PATH 可能很精简，统一用绝对路径调用外部命令。
 */
function dr_bin($name) {
    $map = [
        'bash' => ['/bin/bash', '/usr/bin/bash'],
        'df'   => ['/bin/df', '/usr/bin/df'],
        'sed'  => ['/bin/sed', '/usr/bin/sed'],
    ];
    if (isset($map[$name])) {
        foreach ($map[$name] as $p) {
            if (is_file($p) && is_executable($p)) {
                return $p;
            }
        }
    }
    return $name;
}

function dr_h($s) {
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function dr_mb($bytes, $digits = 1) {
    $bytes = (float)$bytes;
    $units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    $i = 0;
    while ($bytes >= 1024 && $i < count($units) - 1) {
        $bytes /= 1024;
        $i++;
    }
    return ($i === 0 ? (string)(int)$bytes : number_format($bytes, $digits)) . ' ' . $units[$i];
}

/** 读取 key=value 状态文件 */
function dr_read_kv($file) {
    $out = [];
    if (!is_file($file) || !is_readable($file)) {
        return $out;
    }
    $lines = @file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!is_array($lines)) {
        return $out;
    }
    foreach ($lines as $line) {
        $pos = strpos($line, '=');
        if ($pos === false) {
            continue;
        }
        $k = substr($line, 0, $pos);
        $v = substr($line, $pos + 1);
        if ($k !== '') {
            $out[$k] = $v;
        }
    }
    return $out;
}

/** 当前运行信息（running 文件由 api.php 在启动脚本时写入） */
function dr_run_info() {
    $info = dr_read_kv(DR_RUNNING);
    $pid = isset($info['pid']) ? (int)$info['pid'] : 0;
    $alive = false;
    if ($pid > 0) {
        $proc = '/proc/' . $pid;
        if (is_dir($proc)) {
            // 防止 PID 复用：确认这个 PID 确实是我们的脚本
            $cmdline = @file_get_contents($proc . '/cmdline');
            if (is_string($cmdline) && $cmdline !== '') {
                $alive = (strpos($cmdline, 'disk-rescue.sh') !== false);
            } else {
                $alive = is_dir($proc);
            }
        } elseif (function_exists('posix_kill')) {
            $alive = @posix_kill($pid, 0);
        }
    }
    $info['pid'] = $pid;
    $info['alive'] = $alive;
    return $info;
}

/** 最近一次运行的状态 + 进程存活状态 */
function dr_status() {
    $run = dr_run_info();
    $st = dr_read_kv(DR_STATE . '/status');
    if (!$st) {
        $st = [
            'state' => 'idle', 'phase' => 'idle', 'phase_num' => 0, 'total' => 0, 'done' => 0,
            'ok' => 0, 'skipped' => 0, 'failed' => 0, 'bytes_done' => 0, 'speed_bps' => 0,
            'cur_file' => '', 'cur_size' => 0, 'cur_copied' => 0, 'detail' => '',
            'start_ts' => 0, 'end_ts' => 0,
        ];
    }
    if (!$run['alive'] && isset($st['state']) && $st['state'] === 'running') {
        $st['state'] = 'unknown';
        if (empty($st['detail'])) {
            $st['detail'] = '进程已退出（可能被强制终止），请查看日志';
        }
    }
    $st['alive'] = $run['alive'];
    $st['pid'] = $run['pid'];
    $st['log'] = isset($run['log']) ? $run['log'] : '';
    $st['src'] = isset($run['src']) ? $run['src'] : (isset($st['src']) ? $st['src'] : '');
    $st['dst'] = isset($run['dst']) ? $run['dst'] : (isset($st['dst']) ? $st['dst'] : '');
    if (!isset($st['state'])) {
        $st['state'] = 'idle';
    }
    return $st;
}

/** 读取插件配置 */
function dr_config() {
    $defaults = [
        'min_speed'     => 10,
        'speed_window'  => 10,
        'check'         => 2,
        'max_stall'     => 1,
        'grace_factor'  => 2,
        'grace_max'     => 900,
        'grace_small'   => 10,
        'skip_existing' => 0,
        'sync'          => 1,
        'find_timeout'  => 120,
        'src'           => '',
        'dst'           => '',
    ];
    $cfg = dr_read_kv(DR_CFG);
    foreach ($defaults as $k => $v) {
        if (!array_key_exists($k, $cfg) || $cfg[$k] === '') {
            $cfg[$k] = $v;
        }
    }
    return $cfg;
}

function dr_save_config(array $cfg) {
    @mkdir(DR_BOOT, 0755, true);
    $lines = [];
    foreach ($cfg as $k => $v) {
        $lines[] = $k . '=' . str_replace(["\r", "\n"], '', (string)$v);
    }
    return @file_put_contents(DR_CFG, implode("\n", $lines) . "\n") !== false;
}

/**
 * 校验前端提交的路径。
 * 返回 [规范化后的路径, 错误信息]
 */
function dr_check_path($path, $mustExist = true) {
    $path = trim((string)$path);
    if ($path === '' || strlen($path) > 4096) {
        return [null, '路径不能为空'];
    }
    if (strpos($path, "\0") !== false || preg_match('/[\r\n]/', $path)) {
        return [null, '路径包含非法字符'];
    }
    if ($path[0] !== '/') {
        return [null, '必须使用以 / 开头的绝对路径'];
    }
    if (preg_match('#(^|/)\.\.(/|$)#', $path)) {
        return [null, '路径不能包含 ..'];
    }
    $trimmed = rtrim($path, '/');
    if ($trimmed === '') {
        return [null, '不能使用根目录 /'];
    }
    if ($trimmed !== '/mnt' && strpos($trimmed, '/mnt/') !== 0) {
        return [null, '路径必须位于 /mnt 下（例如 /mnt/disk1/... 或 /mnt/user/...）'];
    }
    // 防止通过软链接把路径带到 /mnt 之外
    $real = @realpath($trimmed);
    if ($real !== false && $real !== '/mnt' && strpos($real, '/mnt/') !== 0) {
        return [null, '该路径实际指向 /mnt 之外（' . $real . '），已拒绝'];
    }
    if ($mustExist && !is_dir($trimmed)) {
        return [null, '目录不存在或未挂载: ' . $trimmed];
    }
    return [$trimmed, null];
}

/** 把外部命令输出转成数组（每行一条，去掉尾部空行） */
function dr_lines($out) {
    $out = str_replace(["\r\n", "\r"], "\n", (string)$out);
    $lines = explode("\n", $out);
    while ($lines && end($lines) === '') {
        array_pop($lines);
    }
    return $lines;
}

/** 已挂载的磁盘 / 池 / 共享，用于界面提示与选择 */
function dr_disks() {
    $list = [];
    clearstatcache();
    $dirs = @scandir('/mnt');
    if (!is_array($dirs)) {
        return $list;
    }
    $kinds = [
        'disk' => '磁盘', 'cache' => '缓存池', 'user' => '用户共享',
        'user0' => '用户共享', 'zfs' => 'ZFS',
    ];
    foreach ($dirs as $d) {
        if ($d === '.' || $d === '..') {
            continue;
        }
        $full = '/mnt/' . $d;
        if (!is_dir($full)) {
            continue;
        }
        $label = $d;
        if (preg_match('/^([a-z]+)(\d+)$/', $d, $m) && isset($kinds[$m[1]])) {
            $label = $kinds[$m[1]] . ' ' . $m[2];
        } elseif (isset($kinds[$d])) {
            $label = $kinds[$d];
        }
        $total = 0;
        $avail = 0;
        $df = @shell_exec(dr_bin('df') . ' -Pk ' . escapeshellarg($full) . ' 2>/dev/null');
        if (is_string($df)) {
            foreach (dr_lines($df) as $i => $line) {
                if ($i === 0) {
                    continue;
                }
                $cols = preg_split('/\s+/', trim($line));
                if (count($cols) >= 4) {
                    $total = (int)$cols[1] * 1024;
                    $avail = (int)$cols[3] * 1024;
                }
                break;
            }
        }
        $list[] = [
            'path' => $full,
            'name' => $d,
            'label' => $label,
            'total' => $total,
            'avail' => $avail,
        ];
    }
    usort($list, function ($a, $b) {
        $rank = function ($n) {
            if ($n === 'user') return 0;
            if ($n === 'cache') return 5;
            if (preg_match('/^disk(\d+)$/', $n, $m)) return 10 + (int)$m[1];
            return 500;
        };
        $ra = $rank($a['name']);
        $rb = $rank($b['name']);
        if ($ra === $rb) {
            return strcasecmp($a['name'], $b['name']);
        }
        return $ra <=> $rb;
    });
    return $list;
}

/**
 * 浏览 /mnt 下的目录（供界面选择器使用）。
 * 只允许 /mnt 及其子目录。
 */
function dr_browse($path) {
    $path = trim((string)$path);
    if ($path === '') {
        $path = '/mnt';
    }
    if (strpos($path, "\0") !== false || preg_match('/[\r\n]/', $path)) {
        return [null, '路径包含非法字符'];
    }
    if ($path[0] !== '/') {
        return [null, '必须是绝对路径'];
    }
    if (preg_match('#(^|/)\.\.(/|$)#', $path)) {
        return [null, '路径不能包含 ..'];
    }
    $path = rtrim($path, '/');
    if ($path === '') {
        $path = '/mnt';
    }
    if ($path !== '/mnt' && strpos($path, '/mnt/') !== 0) {
        return [null, '只能浏览 /mnt 下的目录'];
    }
    // 软链接解析后必须仍在 /mnt 下，避免借软链浏览系统目录
    $real = @realpath($path);
    if ($real === false) {
        return [null, '目录不存在: ' . $path];
    }
    if ($real !== '/mnt' && strpos($real, '/mnt/') !== 0) {
        return [null, '该目录实际指向 /mnt 之外（' . $real . '），已拒绝'];
    }
    if (!is_dir($real)) {
        return [null, '目录不存在: ' . $path];
    }
    $dh = @opendir($path);
    if ($dh === false) {
        return [null, '没有权限读取: ' . $path];
    }
    $entries = [];
    while (($e = readdir($dh)) !== false) {
        if ($e === '.' || $e === '..') {
            continue;
        }
        $full = ($path === '/' ? '' : $path) . '/' . $e;
        if (!is_dir($full)) {
            continue;
        }
        $entries[] = [
            'name' => $e,
            'path' => $full,
            'link' => is_link($full),
        ];
    }
    closedir($dh);
    usort($entries, function ($a, $b) {
        if ($a['link'] !== $b['link']) {
            return $a['link'] ? 1 : -1;
        }
        return strnatcasecmp($a['name'], $b['name']);
    });
    $entries = array_slice($entries, 0, 1000);
    $avail = 0;
    $df = @shell_exec(dr_bin('df') . ' -Pk ' . escapeshellarg($path) . ' 2>/dev/null');
    if (is_string($df)) {
        foreach (dr_lines($df) as $i => $line) {
            if ($i === 0) {
                continue;
            }
            $cols = preg_split('/\s+/', trim($line));
            if (count($cols) >= 4) {
                $avail = (int)$cols[3] * 1024;
            }
            break;
        }
    }
    return [[
        'path' => $path,
        'parent' => ($path === '/mnt') ? null : dirname($path),
        'entries' => $entries,
        'avail' => $avail,
    ], null];
}

function dr_json($data, $code = 200) {
    if (!headers_sent()) {
        http_response_code($code);
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-store');
        header('X-Content-Type-Options: nosniff');
    }
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/**
 * 读取 Unraid webGUI 的 CSRF token。
 *
 * 页面里由 webGUI 注入全局变量 $csrf_token（旧版本是 $var['csrf_token']）；
 * 独立请求的 api.php 拿不到这些变量，于是从 /var/local/emhttp/var.ini 里读。
 * 三条来源任取其一，保证「页面渲染时的 token」和「接口校验用的 token」一致。
 */
function dr_csrf_token() {
    global $csrf_token, $var;
    // 容器里没有 webGUI，用环境变量提供固定 token（留空则关闭校验）
    $env = getenv('DR_CSRF_TOKEN');
    if ($env !== false && $env !== '') {
        return $env;
    }
    if (isset($csrf_token) && is_string($csrf_token) && $csrf_token !== '') {
        return $csrf_token;
    }
    if (isset($var['csrf_token']) && (string)$var['csrf_token'] !== '') {
        return (string)$var['csrf_token'];
    }
    static $cached = null;
    if ($cached !== null) {
        return $cached;
    }
    $cached = '';
    foreach (['/var/local/emhttp/var.ini', '/boot/config/var.ini'] as $ini) {
        if (!is_file($ini) || !is_readable($ini)) {
            continue;
        }
        $s = @file_get_contents($ini);
        if (!is_string($s)) {
            continue;
        }
        if (preg_match('/^csrf_token\s*=\s*"?([^"\r\n]*)"?/mi', $s, $m)) {
            $cached = trim($m[1]);
            break;
        }
    }
    return $cached;
}

/**
 * CSRF 校验。
 * 取不到 token 时（极旧版本 / CLI 调用）降级为不校验，此时仍依赖 webGUI 自身鉴权。
 */
function dr_csrf_ok() {
    $expect = dr_csrf_token();
    if ($expect === '') {
        return true;
    }
    $got = isset($_POST['csrf_token']) ? (string)$_POST['csrf_token'] : '';
    if ($got === '' && isset($_SERVER['HTTP_X_CSRF_TOKEN'])) {
        $got = (string)$_SERVER['HTTP_X_CSRF_TOKEN'];
    }
    return hash_equals($expect, $got);
}
