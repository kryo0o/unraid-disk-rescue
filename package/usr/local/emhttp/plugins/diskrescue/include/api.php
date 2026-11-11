<?php
/**
 * diskrescue AJAX 接口
 *
 * 动作:
 *   status    读取运行状态与新增日志（GET）
 *   start     启动抢救任务（POST）
 *   stop      停止当前任务（POST）
 *   browse    浏览 /mnt 下的目录（GET）
 *   info      磁盘列表与默认配置（GET）
 *   clear     清空最近一次状态（POST，仅在没有任务运行时）
 */

require_once __DIR__ . '/helpers.php';

$action = isset($_GET['action']) ? (string)$_GET['action'] : '';
if ($action === '' && isset($_POST['action'])) {
    $action = (string)$_POST['action'];
}
if (!preg_match('/^[a-z]+$/', $action)) {
    dr_json(['ok' => false, 'error' => '未知操作'], 400);
}

// ---------------------------------------------------------------- doctor ----
// 环境自检：容器里排障用。GET /api.php?action=doctor
if ($action === 'doctor') {
    $which = function ($cmd) {
        $out = @shell_exec('command -v ' . $cmd . ' 2>/dev/null');
        $out = is_string($out) ? trim($out) : '';
        return $out !== '' ? $out : null;
    };
    $disabled = array_map('trim', explode(',', (string)ini_get('disable_functions')));
    $checks = [
        'php'           => PHP_VERSION,
        'sapi'          => PHP_SAPI,
        'user'          => function_exists('posix_getpwuid')
            ? (posix_getpwuid(posix_geteuid())['name'] ?? '') : '',
        'shell_exec'    => function_exists('shell_exec') && !in_array('shell_exec', $disabled, true),
        'posix'         => function_exists('posix_kill'),
        'base'          => DR_BASE,
        'data'          => DR_BOOT,
        'data_writable' => is_dir(DR_STATE) && is_writable(DR_STATE),
        'mnt_readable'  => is_dir('/mnt') && is_readable('/mnt'),
        'csrf'          => dr_csrf_token() !== '',
        'script'        => is_file(DR_BASE . '/scripts/disk-rescue.sh') ? 'ok' : 'missing',
    ];
    foreach (['bash', 'setsid', 'dd', 'find', 'timeout', 'nice', 'awk', 'df', 'stat', 'cp', 'sed'] as $b) {
        $checks['bin_' . $b] = $which($b);
    }
    dr_json(['ok' => true, 'checks' => $checks]);
}

// ---------------------------------------------------------------- status ----
if ($action === 'status') {
    $st = dr_status();

    $off = isset($_GET['offset']) ? (int)$_GET['offset'] : 0;
    if ($off < 0) {
        $off = 0;
    }
    $chunk = '';
    $next = $off;
    $log = isset($st['log']) ? $st['log'] : DR_STATE . '/disk-rescue.log';
    if ($log !== '' && is_file($log) && is_readable($log)) {
        $size = (int)@filesize($log);
        if ($off > $size) {
            $off = 0; // 日志被截断/轮转
        }
        $fh = @fopen($log, 'rb');
        if ($fh) {
            fseek($fh, $off);
            $chunk = (string)fread($fh, 262144);
            fclose($fh);
        }
        $next = $off + strlen($chunk);
        // 不返回不完整的最后一行，等下次轮询再取
        $pos = strrpos($chunk, "\n");
        if ($pos === false) {
            $next = $off;
            $chunk = '';
        } elseif ($pos !== strlen($chunk) - 1) {
            $next = $off + $pos + 1;
            $chunk = substr($chunk, 0, $pos + 1);
        }
    }

    dr_json([
        'ok'      => true,
        'st'      => $st,
        'new'     => $chunk,
        'offset'  => $next,
        'now'     => time(),
    ]);
}

// ----------------------------------------------------------------- start ----
if ($action === 'start') {
    if (!dr_csrf_ok()) {
        dr_json(['ok' => false, 'error' => '会话校验失败，请刷新页面后重试'], 403);
    }

    $run = dr_run_info();
    if ($run['alive']) {
        dr_json(['ok' => false, 'error' => '已有抢救任务在运行（PID ' . $run['pid'] . '），请先停止']);
    }

    list($src, $err) = dr_check_path(isset($_POST['src']) ? $_POST['src'] : '');
    if ($err !== null) {
        dr_json(['ok' => false, 'error' => '源目录: ' . $err]);
    }
    list($dst, $err) = dr_check_path(isset($_POST['dst']) ? $_POST['dst'] : '', false);
    if ($err !== null) {
        dr_json(['ok' => false, 'error' => '目标目录: ' . $err]);
    }

    $canon = function ($p) {
        $p = str_replace('\\', '/', $p);
        $parts = [];
        foreach (explode('/', $p) as $seg) {
            if ($seg === '' || $seg === '.') {
                continue;
            }
            if ($seg === '..') {
                array_pop($parts);
                continue;
            }
            $parts[] = $seg;
        }
        return '/' . implode('/', $parts);
    };
    $csrc = $canon($src);
    $cdst = $canon($dst);

    // 不允许把整个 /mnt 或整个共享根当作源，容易误扫全部磁盘
    $tooBroad = ['/mnt', '/mnt/user', '/mnt/user0', '/mnt/disks', '/mnt/remotes'];
    if (in_array($csrc, $tooBroad, true)) {
        dr_json(['ok' => false, 'error' => '源目录范围过大，请选择具体的子目录（例如 /mnt/disk1/xxx）']);
    }
    if (in_array($cdst, $tooBroad, true)) {
        dr_json(['ok' => false, 'error' => '目标目录范围过大，请选择具体的子目录']);
    }

    if ($csrc === $cdst) {
        dr_json(['ok' => false, 'error' => '源目录与目标目录不能相同']);
    }
    $csrcPrefix = ($csrc === '/') ? '/' : rtrim($csrc, '/') . '/';
    if (strpos($cdst . '/', $csrcPrefix) === 0) {
        dr_json(['ok' => false, 'error' => '目标目录不能位于源目录内部（会递归复制）']);
    }

    // 软链接可能绕过上面的字符串判断，这里再按真实路径检查一次
    $rsrc = @realpath($src);
    $rdst = @realpath($dst);
    if ($rsrc !== false && $rdst !== false) {
        if ($rsrc === $rdst) {
            dr_json(['ok' => false, 'error' => '源目录与目标目录实际是同一个目录']);
        }
        if (strpos($rdst . '/', rtrim($rsrc, '/') . '/') === 0) {
            dr_json(['ok' => false, 'error' => '目标目录实际位于源目录内部（软链接），已拒绝']);
        }
    }

    $minSpeed = isset($_POST['min_speed']) ? trim((string)$_POST['min_speed']) : '10';
    $window   = isset($_POST['speed_window']) ? trim((string)$_POST['speed_window']) : '10';
    $check    = isset($_POST['check']) ? trim((string)$_POST['check']) : '2';
    $stall    = isset($_POST['max_stall']) ? trim((string)$_POST['max_stall']) : '1';
    $gFactor  = isset($_POST['grace_factor']) ? trim((string)$_POST['grace_factor']) : '2';
    $gMax     = isset($_POST['grace_max']) ? trim((string)$_POST['grace_max']) : '900';
    $gSmall   = isset($_POST['grace_small']) ? trim((string)$_POST['grace_small']) : '10';
    $sync     = (isset($_POST['sync']) && (string)$_POST['sync'] === '1') ? 1 : 0;
    $findTo   = 120;

    if (!preg_match('/^\d{1,5}$/', $minSpeed) || (int)$minSpeed > 10240) {
        dr_json(['ok' => false, 'error' => '最低速度必须是 0~10240 之间的整数']);
    }
    if (!preg_match('/^\d{1,4}$/', $window) || (int)$window < 2 || (int)$window > 3600) {
        dr_json(['ok' => false, 'error' => '统计窗口必须是 2~3600 秒']);
    }
    if (!preg_match('/^\d{1,3}$/', $check) || (int)$check < 1 || (int)$check > 60) {
        dr_json(['ok' => false, 'error' => '采样间隔必须是 1~60 秒']);
    }
    if (!preg_match('/^\d{1,3}$/', $stall) || (int)$stall < 1 || (int)$stall > 100) {
        dr_json(['ok' => false, 'error' => '连续次数必须是 1~100']);
    }
    if (!preg_match('/^\d{1,3}$/', $gFactor) || (int)$gFactor > 100) {
        dr_json(['ok' => false, 'error' => '宽限倍数必须是 0~100（0 = 不按大小放宽）']);
    }
    if (!preg_match('/^\d{1,5}$/', $gMax) || (int)$gMax < 5 || (int)$gMax > 86400) {
        dr_json(['ok' => false, 'error' => '宽限上限必须是 5~86400 秒']);
    }
    if (!preg_match('/^\d{1,4}$/', $gSmall) || (int)$gSmall < 1 || (int)$gSmall > 3600) {
        dr_json(['ok' => false, 'error' => '小文件宽限必须是 1~3600 秒']);
    }

    $skipExisting = (isset($_POST['skip_existing']) && (string)$_POST['skip_existing'] === '1') ? 1 : 0;
    $dryRun = (isset($_POST['dry_run']) && (string)$_POST['dry_run'] === '1') ? 1 : 0;
    $force = (isset($_POST['force']) && (string)$_POST['force'] === '1') ? 1 : 0;

    if (!is_dir($dst)) {
        dr_json(['ok' => false, 'error' => '目标目录不存在: ' . $dst . '（请先在 /mnt 下创建）']);
    }
    if (!is_writable($dst)) {
        dr_json(['ok' => false, 'error' => '目标目录不可写: ' . $dst]);
    }

    // 源与目标在同一文件系统时给出提示（不阻止，但不建议）
    $sameDev = false;
    $dfCmd = function ($p) {
        $o = @shell_exec(dr_bin('df') . ' -P ' . escapeshellarg($p) . ' 2>/dev/null');
        if (!is_string($o)) {
            return '';
        }
        $lines = array_values(array_filter(explode("\n", str_replace("\r", '', $o))));
        if (count($lines) < 2) {
            return '';
        }
        $cols = preg_split('/\s+/', trim($lines[1]));
        return isset($cols[0]) ? $cols[0] : '';
    };
    $sdev = $dfCmd($src);
    $ddev = $dfCmd($dst);
    if ($sdev !== '' && $sdev === $ddev) {
        $sameDev = true;
    }

    $minSpeed = (int)$minSpeed;
    $window   = (int)$window;
    $check    = (int)$check;
    $stall    = (int)$stall;
    $gFactor  = (int)$gFactor;
    $gMax     = (int)$gMax;
    $gSmall   = (int)$gSmall;

    dr_save_config([
        'min_speed'     => $minSpeed,
        'speed_window'  => $window,
        'check'         => $check,
        'max_stall'     => $stall,
        'grace_factor'  => $gFactor,
        'grace_max'     => $gMax,
        'grace_small'   => $gSmall,
        'skip_existing' => $skipExisting,
        'sync'          => $sync,
        'find_timeout'  => $findTo,
        'src'           => $src,
        'dst'           => $dst,
    ]);

    @mkdir(DR_TMP, 0755, true);
    @mkdir(DR_STATE, 0755, true);
    $stamp = date('Ymd-His');
    $log = DR_STATE . '/disk-rescue-' . $stamp . '.log';
    @touch($log);
    @chmod($log, 0644);

    $statusFile = DR_STATE . '/status';
    @unlink($statusFile);

    $args = [
        '--src=' . $src,
        '--dst=' . $dst,
        '--min-speed=' . $minSpeed,
        '--speed-window=' . $window,
        '--check=' . $check,
        '--max-stall=' . $stall,
        '--grace-factor=' . $gFactor,
        '--grace-max=' . $gMax,
        '--grace-small=' . $gSmall,
        '--find-timeout=' . $findTo,
        '--log-file=' . $log,
        '--status-file=' . $statusFile,
        '--yes',
    ];
    if ($skipExisting === 1) {
        $args[] = '--skip-existing';
    }
    if ($dryRun === 1) {
        $args[] = '--dry-run';
    }
    if ($sync === 1) {
        $args[] = '--sync';
    } else {
        $args[] = '--no-sync';
    }
    if ($force === 1) {
        $args[] = '--force';
    }

    $q = [];
    foreach ($args as $a) {
        $q[] = escapeshellarg($a);
    }
    $setsid = '/usr/bin/setsid';
    if (!is_file($setsid)) {
        $setsid = '';
    }
    $cmd = 'nohup ' . ($setsid !== '' ? $setsid . ' ' : '')
         . escapeshellarg(dr_bin('bash')) . ' ' . escapeshellarg(DR_BASE . '/scripts/disk-rescue.sh')
         . ' ' . implode(' ', $q) . ' >/dev/null 2>&1 & echo $!';
    $pid = (int)trim((string)@shell_exec($cmd));
    if ($pid <= 0) {
        dr_json(['ok' => false, 'error' => '无法启动抢救进程，请检查插件文件是否完整（scripts/disk-rescue.sh）']);
    }

    // 只保留最近 10 份日志，避免写满引导 U 盘
    $logs = glob(DR_STATE . '/disk-rescue-*.log');
    if (is_array($logs) && count($logs) > 10) {
        sort($logs);
        $drop = array_slice($logs, 0, count($logs) - 10);
        foreach ($drop as $old) {
            if ($old !== $log) {
                @unlink($old);
            }
        }
    }

    $runData = [
        'pid'       => $pid,
        'log'       => $log,
        'src'       => $src,
        'dst'       => $dst,
        'min_speed' => $minSpeed,
        'check'     => $check,
        'max_stall' => $stall,
        'dry_run'   => $dryRun,
        'started'   => time(),
    ];
    $tmp = DR_RUNNING . '.tmp';
    $kv = '';
    foreach ($runData as $k => $v) {
        $kv .= $k . '=' . $v . "\n";
    }
    if (@file_put_contents($tmp, $kv) === false || !@rename($tmp, DR_RUNNING)) {
        @file_put_contents(DR_RUNNING, $kv);
    }

    // 等脚本写出第一版状态，避免前端第一次轮询时还以为在 idle
    $waited = 0;
    while ($waited < 20) {
        usleep(100000);
        $waited++;
        if (is_file($statusFile)) {
            break;
        }
    }

    // 脚本如果瞬间退出（参数/权限问题），把日志尾部返回给前端，而不是让页面一直显示 idle
    if (!is_file($statusFile)) {
        $alive = function_exists('posix_kill') ? @posix_kill($pid, 0) : is_dir('/proc/' . $pid);
        if (!$alive) {
            $tail = '';
            if (is_file($log)) {
                $lines = @file($log, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
                if (is_array($lines)) {
                    $tail = implode(' | ', array_slice($lines, -3));
                }
            }
            dr_json([
                'ok'    => false,
                'error' => '任务启动后立即退出' . ($tail !== '' ? '：' . $tail : '，请检查日志'),
            ]);
        }
    }

    dr_json([
        'ok'       => true,
        'pid'      => $pid,
        'log'      => $log,
        'started'  => time(),
        'same_dev' => $sameDev,
        'cfg'      => [
            'min_speed'     => $minSpeed,
            'speed_window'  => $window,
            'check'         => $check,
            'max_stall'     => $stall,
            'grace_factor'  => $gFactor,
            'grace_max'     => $gMax,
            'grace_small'   => $gSmall,
            'skip_existing' => $skipExisting,
            'sync'          => $sync,
            'dry_run'       => $dryRun,
        ],
    ]);
}

// ------------------------------------------------------------------ stop ----
if ($action === 'stop') {
    if (!dr_csrf_ok()) {
        dr_json(['ok' => false, 'error' => '会话校验失败，请刷新页面后重试'], 403);
    }
    $run = dr_run_info();
    if (!$run['alive'] || $run['pid'] <= 0) {
        @unlink(DR_RUNNING);
        dr_json(['ok' => true, 'msg' => '当前没有正在运行的抢救任务']);
    }
    $pid = $run['pid'];
    if (function_exists('posix_kill')) {
        @posix_kill($pid, 15);
    } else {
        @shell_exec('kill -TERM ' . (int)$pid . ' 2>/dev/null');
    }
    $waited = 0;
    $alive = true;
    // 脚本收到 TERM 后要给 dd 最多 10 秒收尾、并把已读数据改名成 .partial，
    // 这里只等 5 秒；不要轻易 SIGKILL，否则会丢掉部分数据和最终状态。
    while ($waited < 50) {
        usleep(100000);
        $waited++;
        $alive = function_exists('posix_kill') ? @posix_kill($pid, 0) : is_dir('/proc/' . $pid);
        if (!$alive) {
            break;
        }
    }

    // 只有用户二次确认“强制停止”时才 SIGKILL
    $forced = false;
    if ($alive && isset($_POST['force']) && (string)$_POST['force'] === '1') {
        if (function_exists('posix_kill')) {
            @posix_kill($pid, 9);
        } else {
            @shell_exec('kill -KILL ' . (int)$pid . ' 2>/dev/null');
        }
        $forced = true;
        usleep(300000);
    }

    if (!$alive || $forced) {
        @unlink(DR_RUNNING);
    }

    if ($forced) {
        $msg = '已强制结束抢救进程（未保留 .partial）';
    } elseif ($alive) {
        $msg = '已发送停止信号，脚本正在收尾（最多约 10 秒），可稍后刷新查看';
    } else {
        $msg = '已停止，未完成的数据已保留为 .partial';
    }

    dr_json([
        'ok'  => true,
        'msg' => $msg,
    ]);
}

// ---------------------------------------------------------------- browse ----
if ($action === 'browse') {
    list($data, $err) = dr_browse(isset($_GET['path']) ? $_GET['path'] : '/mnt');
    if ($err !== null) {
        dr_json(['ok' => false, 'error' => $err], 400);
    }
    dr_json(['ok' => true, 'data' => $data]);
}

// ------------------------------------------------------------------ info ----
if ($action === 'info') {
    $st = dr_status();
    $cfg = dr_config();
    dr_json([
        'ok'    => true,
        'disks' => dr_disks(),
        'cfg'   => $cfg,
        'st'    => $st,
    ]);
}

// ----------------------------------------------------------------- clear ----
if ($action === 'clear') {
    if (!dr_csrf_ok()) {
        dr_json(['ok' => false, 'error' => '会话校验失败，请刷新页面后重试'], 403);
    }
    $run = dr_run_info();
    if ($run['alive']) {
        dr_json(['ok' => false, 'error' => '任务运行中，不能清空状态']);
    }
    @unlink(DR_STATE . '/status');
    @unlink(DR_RUNNING);
    dr_json(['ok' => true]);
}

dr_json(['ok' => false, 'error' => '未知操作: ' . $action], 400);
