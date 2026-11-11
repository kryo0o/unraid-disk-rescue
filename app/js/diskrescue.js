/* =============================================================================
 * diskrescue - 前端逻辑
 * 依赖 webGUI 自带的 jQuery，页面内不引入其它库。
 * ========================================================================== */
(function () {
  'use strict';

  if (typeof jQuery === 'undefined') {
    return;
  }
  var $ = jQuery;

  var POLL_MS = 2000;
  var MAX_LOG_LINES = 4000;

  var $app        = $('#dr-app');
  var $form       = $('#dr-form');
  var $start      = $('#dr-start');
  var $stop       = $('#dr-stop');
  var $note       = $('#dr-note');
  var $log        = $('#dr-log');
  var $bar        = $('#dr-bar');
  var $state      = $('#dr-state');
  var $detail     = $('#dr-detail');
  var $speed      = $('#dr-speed');
  var $avg        = $('#dr-avg');
  var $elapsed    = $('#dr-elapsed');
  var $counts     = $('#dr-counts');
  var $curfile    = $('#dr-curfile');
  var $bytes      = $('#dr-bytes');
  var $ok         = $('#dr-ok');
  var $skip       = $('#dr-skip');
  var $fail       = $('#dr-fail');
  var $progressCard = $('#dr-progress-card');
  var $runningTip = $('#dr-running-tip');
  var $autoscroll = $('#dr-autoscroll');

  var api   = $('#dr-api').val();
  var csrf  = $('#dr-csrf').val() || '';
  var offset = 0;
  var curLogPath = '';
  var timer = null;
  var busy = false;
  var lastState = '';
  var pollErrors = 0;
  var startedAt = 0;

  var PHASE_LABEL = {
    0: '待机', 1: '检查环境', 2: '创建目录', 3: '枚举文件',
    4: '复制中', 5: '预扫描', 6: '已完成'
  };
  var STATE_LABEL = {
    idle: '待机', running: '运行中', finished: '已完成',
    stopped: '已停止', failed: '失败', unknown: '异常退出'
  };

  function apiUrl(params) {
    var q = [];
    for (var k in params) {
      if (Object.prototype.hasOwnProperty.call(params, k)) {
        q.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
      }
    }
    return api + (q.length ? '?' + q.join('&') : '');
  }

  function get(params, cb) {
    $.ajax({
      url: apiUrl(params),
      method: 'GET',
      dataType: 'json',
      cache: false,
      timeout: 20000
    }).done(function (r) { cb(null, r); })
      .fail(function (xhr) { cb(failMsg(xhr), null); });
  }

  function post(data, cb) {
    var payload = $.extend({ csrf_token: csrf }, data || {});
    $.ajax({
      url: api,
      method: 'POST',
      data: payload,
      dataType: 'json',
      timeout: 30000,
      headers: csrf ? { 'X-CSRF-Token': csrf } : {}
    }).done(function (r) { cb(null, r); })
      .fail(function (xhr) { cb(failMsg(xhr), null); });
  }

  function failMsg(xhr) {
    if (xhr && xhr.responseJSON && xhr.responseJSON.error) {
      return xhr.responseJSON.error;
    }
    if (xhr && xhr.status === 0) {
      return '无法连接 WebGUI，请检查网络或刷新页面';
    }
    if (xhr && xhr.status === 403) {
      return '会话校验失败，请刷新页面后重试';
    }
    if (xhr && xhr.status) {
      return '请求失败（HTTP ' + xhr.status + '）';
    }
    return '请求失败';
  }

  function esc(s) {
    return String(s === undefined || s === null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function human(bytes) {
    var b = Number(bytes) || 0;
    var units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var i = 0;
    while (b >= 1024 && i < units.length - 1) { b /= 1024; i++; }
    return (i === 0 ? Math.round(b) : b.toFixed(1)) + ' ' + units[i];
  }

  function fmtTime(sec) {
    sec = Math.max(0, Math.floor(Number(sec) || 0));
    var h = Math.floor(sec / 3600);
    var m = Math.floor((sec % 3600) / 60);
    var s = sec % 60;
    if (h > 0) return h + ':' + pad(m) + ':' + pad(s);
    return m + ':' + pad(s);
  }
  function pad(n) { return (n < 10 ? '0' : '') + n; }

  /* ---------------------------------------------------------- 日志输出 ---- */
  function logClass(line) {
    if (/❌|失败|错误|错误:/.test(line)) return 'dr-line-fail';
    if (/✅|🎉|全部文件/.test(line)) return 'dr-line-ok';
    if (/⚠|警告|! 速度|跳过/.test(line)) return 'dr-line-warn';
    if (/^\s*↳|^\[.*\] -{5,}/.test(line)) return 'dr-line-dim';
    return '';
  }

  function appendLog(text) {
    if (!text) return;
    var atBottom = $log[0].scrollHeight - $log[0].scrollTop - $log[0].clientHeight < 40;
    var frag = document.createDocumentFragment();
    var lines = String(text).replace(/\r/g, '').split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] === '') continue;
      var span = document.createElement('span');
      var cls = logClass(lines[i]);
      if (cls) span.className = cls;
      span.textContent = lines[i] + '\n';
      frag.appendChild(span);
    }
    // 首次输出前清掉占位文字
    if ($log.data('placeholder') !== 1) {
      $log.empty();
      $log.data('placeholder', 1);
    }
    $log[0].appendChild(frag);
    // 控制行数，避免大目录时浏览器卡顿
    var kids = $log[0].childNodes;
    if (kids.length > MAX_LOG_LINES) {
      for (var j = 0; j < kids.length - MAX_LOG_LINES; j++) {
        $log[0].removeChild($log[0].firstChild);
      }
    }
    if ($autoscroll.is(':checked') || atBottom) {
      $log.scrollTop = $log[0].scrollHeight;
    }
  }

  function resetLog() {
    $log.empty();
    $log.data('placeholder', 1);
    offset = 0;
  }

  /* ---------------------------------------------------------- 状态渲染 ---- */
  function setRunning(on) {
    $start.prop('disabled', on);
    $stop.prop('disabled', !on);
    $('#dr-src, #dr-dst, #dr-min-speed, #dr-speed-window, #dr-check, #dr-max-stall, ' +
      '#dr-hang-timeout, #dr-grace-factor, #dr-grace-max, #dr-grace-small').prop('disabled', on);
    $form.find('input[type=checkbox]').prop('disabled', on);
    $('#dr-clear, #dr-clean-partial, #dr-prune, #dr-prune-mb').prop('disabled', on);
    $runningTip.toggle(!!on);
  }

  function render(st) {
    if (!st) return;

    var state = st.state || 'idle';
    var phase = Number(st.phase_num) || 0;
    var alive = !!st.alive;

    $state.text(STATE_LABEL[state] || state).attr('data-s', state);
    var detail = st.detail || '';
    if (state === 'running' && PHASE_LABEL[phase]) {
      detail = PHASE_LABEL[phase] + (detail ? ' · ' + detail : '');
    }
    $detail.text(detail);
    $state.closest('.dr-card').show();
    $progressCard.show();

    // 阶段条
    $('#dr-phasebar .dr-phase').each(function () {
      var p = Number($(this).data('phase'));
      $(this).toggleClass('on', p <= phase).toggleClass('cur', p === phase && state === 'running');
    });

    // 进度
    var total = Number(st.total) || 0;
    var done = Number(st.done) || 0;
    var pct = total > 0 ? Math.min(100, Math.round(done * 100 / total)) : 0;
    if (state === 'finished' || state === 'stopped' || state === 'failed') {
      if (total > 0) pct = Math.min(100, Math.round(done * 100 / total));
    }
    if (total > 0 && (state === 'finished' ) && done >= total) pct = 100;
    $bar.css('width', pct + '%');

    $counts.text('文件 ' + done + ' / ' + (total || '?') + (total ? '（' + pct + '%）' : ''));
    var cur = st.cur_file ? String(st.cur_file) : '';
    if (state !== 'running') cur = '';
    $curfile.text(cur).attr('title', cur);

    var curSize = Number(st.cur_size) || 0;
    var curCopy = Number(st.cur_copied) || 0;
    if (state === 'running' && cur && curSize > 0) {
      $curfile.text(cur + '  ' + human(curCopy) + ' / ' + human(curSize) +
        ' (' + Math.min(100, Math.floor(curCopy * 100 / curSize)) + '%)');
    }

    $ok.text(Number(st.ok) || 0);
    var existN = Number(st.exists) || 0;
    $skip.text((Number(st.skipped) || 0) + (existN > 0 ? '（已存在 ' + existN + '）' : ''));
    $fail.text(Number(st.failed) || 0);
    $bytes.text('已复制 ' + human(st.bytes_done));

    // 速度 / 时间
    var speed = state === 'running'
      ? (Number(st.win_bps) || Number(st.speed_bps) || 0)
      : 0;
    if (state === 'running') {
      $speed.text(speed > 0 ? human(speed) + '/s' : '—');
    } else {
      $speed.text('—');
    }
    var start = Number(st.start_ts) || 0;
    var end = Number(st.end_ts) || 0;
    if (start > 0) {
      if (state === 'running' && alive) {
        startedAt = startedAt || start;
        var secs = Math.max(0, (Date.now() / 1000) - start);
        $avg.text(human(secs > 0 ? (Number(st.bytes_done) || 0) / secs : 0) + '/s');
        $elapsed.text(fmtTime(secs));
      } else {
        var dur = (end > start ? end - start : 0);
        $avg.text(human(dur > 0 ? (Number(st.bytes_done) || 0) / dur : 0) + '/s');
        $elapsed.text(fmtTime(dur));
      }
    } else {
      $avg.text('—');
      $elapsed.text('—');
    }

    // 进程存活 vs 状态不一致时提示一次
    if (state === 'running' && !alive) {
      $detail.text('任务进程已退出');
    }
    if (lastState === 'running' && state !== 'running' && !alive) {
      setRunning(false);
      stopPolling();
      // 最后再取一次日志尾巴
      pollOnce(true);
    }
    lastState = state;
  }

  /* ------------------------------------------------------------- 轮询 ---- */
  function pollOnce(force) {
    if (busy) return;
    busy = true;
    get({ action: 'status', offset: offset }, function (err, r) {
      busy = false;
      if (err) {
        pollErrors++;
        if (pollErrors >= 5) {
          $note.text('状态轮询失败：' + err);
        }
        return;
      }
      pollErrors = 0;
      // 新一次运行会写到新的日志文件，offset 必须归零
      var lp = (r.st && r.st.log) ? String(r.st.log) : '';
      if (lp && lp !== curLogPath) {
        if (curLogPath !== '') {
          resetLog();
        }
        curLogPath = lp;
      }
      if (typeof r.offset === 'number') offset = r.offset;
      if (r.new) appendLog(r.new);
      render(r.st || {});
      // 只要进程还活着就继续轮询（刚启动时状态文件可能还没写好）
      if (r.st && (r.st.alive || r.st.state === 'running')) {
        startPolling();
      } else {
        stopPolling();
      }
    });
  }

  function startPolling() {
    if (timer) return;
    timer = setInterval(function () { pollOnce(false); }, POLL_MS);
  }

  function stopPolling() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  /* ------------------------------------------------------------- 表单 ---- */
  function collect() {
    var d = {};
    $form.serializeArray().forEach(function (f) { d[f.name] = f.value; });
    return d;
  }

  function validate(d) {
    if (!d.src || !/^\/mnt(\/|$)/.test(d.src)) {
      return '源目录必须是以 /mnt 开头的完整路径';
    }
    if (!d.dst || !/^\/mnt(\/|$)/.test(d.dst)) {
      return '目标目录必须是以 /mnt 开头的完整路径';
    }
    var broad = ['/mnt', '/mnt/user', '/mnt/user0', '/mnt/disks', '/mnt/remotes'];
    var s = d.src.replace(/\/+$/, '');
    var t = d.dst.replace(/\/+$/, '');
    if (broad.indexOf(s) !== -1) {
      return '源目录范围过大，请选择具体的子目录（例如 /mnt/disk1/xxx）';
    }
    if (broad.indexOf(t) !== -1) {
      return '目标目录范围过大，请选择具体的子目录';
    }
    if (s === t) {
      return '源目录与目标目录不能相同';
    }
    if (t.indexOf(s + '/') === 0) {
      return '目标目录不能位于源目录内部';
    }
    var ms = parseInt(d.min_speed, 10);
    if (isNaN(ms) || ms < 0 || ms > 10240) return '最低平均速度无效';
    var w = parseInt(d.speed_window, 10);
    if (isNaN(w) || w < 2 || w > 3600) return '统计窗口必须在 2~3600 秒之间';
    var c = parseInt(d.check, 10);
    if (isNaN(c) || c < 1 || c > 60) return '采样间隔必须在 1~60 秒之间';
    var st = parseInt(d.max_stall, 10);
    if (isNaN(st) || st < 1 || st > 100) return '连续判定次数必须在 1~100 之间';
    var ht = parseInt(d.hang_timeout, 10);
    if (isNaN(ht) || ht < 0 || ht > 3600) return '卡死超时必须在 0~3600 秒之间';
    var gf = parseInt(d.grace_factor, 10);
    if (isNaN(gf) || gf < 0 || gf > 100) return '宽限倍数必须在 0~100 之间';
    var gm = parseInt(d.grace_max, 10);
    if (isNaN(gm) || gm < 5 || gm > 86400) return '宽限上限必须在 5~86400 秒之间';
    var gs = parseInt(d.grace_small, 10);
    if (isNaN(gs) || gs < 1 || gs > 3600) return '小文件宽限必须在 1~3600 秒之间';
    return null;
  }

  $start.on('click', function () {
    var d = collect();
    var err = validate(d);
    if (err) {
      $note.text(err);
      return;
    }
    var dry = d.dry_run === '1';
    var msg = (dry ? '开始预扫描（只读，不复制）？' : '开始复制？请确认目标磁盘有足够空间。') +
      '\n\n源：' + d.src + '\n目标：' + d.dst;
    if (!window.confirm(msg)) return;

    $start.prop('disabled', true);
    $note.text('正在启动…');
    resetLog();
    post($.extend({ action: 'start' }, d), function (e, r) {
      if (e || !r.ok) {
        $note.text(e || r.error || '启动失败');
        $start.prop('disabled', false);
        return;
      }
      $note.text('已启动（PID ' + r.pid + '）' + (r.same_dev ? ' · 注意：源与目标在同一文件系统' : ''));
      setRunning(true);
      lastState = 'running';
      curLogPath = r.log || '';
      $progressCard.show();
      pollOnce(true);
      startPolling();
    });
  });

  $stop.on('click', function () {
    if (!window.confirm('确定停止当前抢救任务？\n\n当前文件会保留为 .partial，已完成的部分不会丢失。')) return;
    $stop.prop('disabled', true);
    $note.text('正在停止…');
    post({ action: 'stop' }, function (e, r) {
      if (e || !r.ok) {
        $note.text(e || r.error || '停止失败');
        $stop.prop('disabled', false);
        return;
      }
      $note.text(r.msg || '已停止');
      pollOnce(true);
    });
  });

  // 清理“没转移成功”的空目录 / 只含未完成文件的小目录（先预览再执行）
  $('#dr-prune').on('click', function () {
    var dir = ($('#dr-dst').val() || '').trim();
    if (!dir) { $note.text('请先填写目标文件夹'); return; }
    var mb = parseInt($('#dr-prune-mb').val(), 10);
    if (isNaN(mb) || mb < 0 || mb > 102400) { $note.text('大小阈值必须在 0~102400 MB 之间'); return; }

    post({ action: 'prune_dirs', dir: dir, max_mb: mb, dry: 1 }, function (e, r) {
      if (e || !r.ok) { $note.text(e || r.error || '预览失败'); return; }
      if (!r.dirs) { $note.text('没有可清理的空/小目录'); return; }

      var lines = r.sample.join('\n');
      if (r.dirs > r.sample.length) lines += '\n…（共 ' + r.dirs + ' 个）';
      var msg = '将删除 ' + r.dirs + ' 个目录';
      if (r.files) msg += '、' + r.files + ' 个未完成文件';
      msg += '（合计 ' + human(r.bytes) + '）\n\n' + lines;
      msg += '\n\n只删除空目录和“只含 .partial 的小目录”，含正常文件的目录不会动。继续？';
      if (!window.confirm(msg)) return;

      post({ action: 'prune_dirs', dir: dir, max_mb: mb, dry: 0 }, function (e2, r2) {
        if (e2 || !r2.ok) { $note.text(e2 || r2.error || '清理失败'); return; }
        $note.text('已清理 ' + r2.dirs + ' 个目录、' + r2.files + ' 个未完成文件（' + human(r2.bytes) + '）');
      });
    });
  });

  $('#dr-clean-partial').on('click', function () {
    var dir = ($('#dr-dst').val() || '').trim();
    if (!dir) { $note.text('请先填写目标文件夹'); return; }
    if (!window.confirm('删除目标目录下所有未完成文件（*.partial）？\n\n' + dir + '\n\n此操作不可恢复。')) return;
    post({ action: 'clean_partial', dir: dir }, function (e, r) {
      if (e || !r.ok) { $note.text(e || r.error || '清理失败'); return; }
      $note.text('已删除 ' + r.removed + ' 个未完成文件（' + human(r.bytes) + '）');
    });
  });

  $('#dr-clear').on('click', function () {
    if (!window.confirm('清空页面显示的状态和日志？（磁盘上的文件不受影响）')) return;
    post({ action: 'clear' }, function (e, r) {
      if (e || !r.ok) { $note.text(e || r.error || '操作失败'); return; }
      resetLog();
      $progressCard.hide();
      $note.text('已清空');
      lastState = 'idle';
    });
  });

  $('#dr-log-clear').on('click', function () {
    var cur = offset;
    resetLog();
    offset = cur;
    $log.text('（已清屏，后续输出继续显示）\n');
  });

  // 快捷目录按钮：填入当前聚焦的输入框
  var lastFocused = $('#dr-src');
  $('#dr-src, #dr-dst').on('focus', function () { lastFocused = $(this); });
  $('.dr-chip').on('click', function () {
    if ($('#dr-src').prop('disabled')) return;
    lastFocused.val($(this).data('path')).trigger('focus');
  });

  // 根据窗口/次数更新提示
  function updateStallHint() {
    var w = parseInt($('#dr-speed-window').val(), 10) || 0;
    var s = parseInt($('#dr-max-stall').val(), 10) || 0;
    var ms = parseInt($('#dr-min-speed').val(), 10) || 0;
    if (w > 0 && s > 0) {
      var txt = '最近 ' + w + ' 秒平均速度低于 ' + ms + 'MB/s';
      txt += s > 1 ? '，连续 ' + s + ' 次判定后跳过。' : ' 即跳过。';
      $('#dr-stall-hint').text(txt);
    }
  }
  $('#dr-speed-window, #dr-max-stall, #dr-min-speed').on('input change', updateStallHint);
  updateStallHint();

  /* --------------------------------------------------------- 目录选择器 ---- */
  var $modal = $('#dr-modal');
  var $mList = $('#dr-modal-list');
  var $mPath = $('#dr-modal-path');
  var $mHint = $('#dr-modal-hint');
  var browseTarget = null;
  var mCurrent = '/mnt';

  function openModal(targetId) {
    browseTarget = '#' + targetId;
    var cur = $(browseTarget).val();
    if (!cur || !/^\/mnt(\/|$)/.test(cur)) cur = '/mnt';
    $modal.addClass('open').attr('aria-hidden', 'false');
    $('#dr-modal-title').text('选择目录（' + (targetId === 'dr-src' ? '源' : '目标') + '）');
    loadDir(cur);
  }

  function closeModal() {
    $modal.removeClass('open').attr('aria-hidden', 'true');
    browseTarget = null;
  }

  function loadDir(path) {
    $mList.html('<div class="dr-modal-empty">读取中…</div>');
    $mHint.text('');
    get({ action: 'browse', path: path }, function (err, r) {
      if (err || !r.ok) {
        $mList.html('<div class="dr-modal-empty">' + esc(err || r.error || '读取失败') + '</div>');
        return;
      }
      var d = r.data;
      mCurrent = d.path;
      $mPath.val(d.path);
      $mHint.text(d.avail ? '可用空间 ' + human(d.avail) : '');
      var rows = [];
      if (d.parent) {
        rows.push('<div class="dr-modal-item" data-path="' + esc(d.parent) + '"><span class="dr-ico">↰</span> 返回上级 <small>' + esc(d.parent) + '</small></div>');
      }
      if (!d.entries.length) {
        rows.push('<div class="dr-modal-empty">此目录下没有子目录</div>');
      }
      d.entries.forEach(function (e) {
        rows.push('<div class="dr-modal-item" data-path="' + esc(e.path) + '">' +
          '<span class="dr-ico">' + (e.link ? '🔗' : '📁') + '</span>' +
          esc(e.name) + '</div>');
      });
      $mList.html(rows.join(''));
    });
  }

  $mList.on('click', '.dr-modal-item', function () {
    var p = $(this).data('path');
    if (p) loadDir(p);
  });

  $mPath.on('keydown', function (e) {
    if (e.key === 'Enter' || e.keyCode === 13) {
      e.preventDefault();
      loadDir($mPath.val());
    }
  });

  $('#dr-modal-ok').on('click', function () {
    if (browseTarget) {
      $(browseTarget).val(mCurrent).trigger('change');
    }
    closeModal();
  });
  $('#dr-modal-close, #dr-modal-cancel').on('click', closeModal);
  $modal.on('click', function (e) {
    if (e.target === this) closeModal();
  });
  $(document).on('keydown', function (e) {
    if ((e.key === 'Escape' || e.keyCode === 27) && $modal.hasClass('open')) closeModal();
  });

  $('[data-browse]').on('click', function () {
    openModal($(this).data('browse'));
  });

  // 刷新按钮
  $('#dr-reload').on('click', function () {
    window.location.reload();
  });

  /* ------------------------------------------------------------- 初始化 ---- */
  $(function () {
    $log.data('placeholder', 0);
    var running = $app.data('running') === 1 || $app.data('running') === '1';
    setRunning(running);
    pollOnce(true);
    if (running) startPolling();
  });
})();
