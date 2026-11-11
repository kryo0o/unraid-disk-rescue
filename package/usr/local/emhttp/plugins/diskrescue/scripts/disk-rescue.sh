#!/bin/bash
# =============================================================================
#  disk-rescue.sh - Unraid 坏盘数据抢救工具（带最低速度检测）
#
#  适配 Unraid 7.x（bash 4.4+ / coreutils / BusyBox 均可运行）
#
#  用法:
#    disk-rescue.sh                     交互模式（控制台直接运行）
#    disk-rescue.sh --src A --dst B     WebGUI 插件调用的非交互模式
#
#  参数:
#    --src PATH            源文件夹（必填）
#    --dst PATH            目标文件夹（必填）
#    --min-speed MB        最低平均速度阈值，0 表示关闭速度监控（默认 10）
#    --speed-window SEC    统计窗口：最近 N 秒的平均速度（默认 10）
#    --check SECONDS       采样间隔（默认 2）
#    --max-stall N         连续多少次判定后跳过（默认 1）
#    --grace-factor N      宽限 = N × (文件大小 / 阈值速度)（默认 2）
#    --grace-max SEC       宽限上限（默认 900）
#    --grace-small SEC     小文件（<4MiB）宽限（默认 10）
#    --find-timeout SEC    目录/文件枚举超时（默认 120）
#    --log-file PATH       日志文件，插件会轮询该文件显示实时输出
#    --status-file PATH    状态文件（key=value），插件据此显示进度
#    --failed-list PATH    失败清单文件，默认写到目标目录
#    --skip-existing       目标已存在且大小一致的文件直接跳过
#    --dry-run             只扫描不复制
#    --sync                复制时使用 conv=fsync（默认开启，速度更真实）
#    --no-sync             关闭 conv=fsync（更快，但页缓存会掩盖真实写入速度）
#    --force               忽略目标空间不足等警告
#    --yes                 不询问确认
#    -h | --help           显示帮助
#
#  退出码:
#    0 全部成功（含“已存在”跳过）
#    1 参数/环境错误
#    2 被用户中断（已保留 .partial）
#    3 有文件失败或卡死被跳过
#
#  说明:
#    - 复制引擎为 dd(bs=1M conv=fsync)：坏扇区处会报错并停止，已读到的字节保留为
#      "<文件>.partial"，方便之后用 ddrescue 等工具补读；健康文件不受影响。
#    - 速度判定看「最近 --speed-window 秒的平均速度」：窗口内平均低于 --min-speed
#      即判定卡死。宽限期内不判定（宽限 = factor × 文件大小 / 阈值，可调）。
#      用窗口平均而不是瞬时速度，是为了避免把"正在刷缓存/正在写入慢盘"误判成卡死。
# =============================================================================

SCRIPT_NAME="disk-rescue.sh"

# ---------------------------------- 默认值 ----------------------------------
SRC=""
DST=""
MIN_SPEED_MB=10
SPEED_WINDOW=10
CHECK_INTERVAL=2
MAX_STALL=1
GRACE_FACTOR=2
GRACE_MAX=900
GRACE_SMALL=10
FIND_TIMEOUT=120
LOG_FILE=""
STATUS_FILE=""
FAILED_LIST=""
SKIP_EXISTING=0
DRY_RUN=0
USE_SYNC=1
FORCE=0
ASSUME_YES=0
INTERACTIVE=0

# ---------------------------------- 运行变量 --------------------------------
PHASE="idle"
STATE="running"
STATE_DETAIL=""
TOTAL=0
DONE_N=0
OK_N=0
SKIP_N=0
EXIST_N=0
FAIL_N=0
BYTES_DONE=0
CUR_FILE=""
CUR_SIZE=0
CUR_COPIED=0
WIN_BPS=0
START_TS=$(date +%s)
LAST_BEAT=0
LAST_STATUS=0
LOG_WRITES=0
STOP_SIGNAL=0
CURRENT_PID=""
PARTIAL_FILE=""

# ---------------------------------- 输出 ------------------------------------
# 当前时间（毫秒）。优先用 %N 纳秒精度；BusyBox 上退化为秒精度。
now_ms() {
    local t
    t=$(date +%s%N 2>/dev/null)
    case "$t" in
        ''|*[!0-9]*) t="$(date +%s)000000000" ;;
    esac
    printf '%s' "$((t / 1000000))"
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local line
    line="[$(ts)] $*"
    if [ -n "$LOG_FILE" ]; then
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
        LOG_WRITES=$((LOG_WRITES + 1))
        # 每 100 行检查一次大小，避免日志写满引导 U 盘（最多 5MB）
        if [ $((LOG_WRITES % 100)) -eq 0 ] && [ -f "$LOG_FILE" ]; then
            local sz
            sz=$(stat -c %s "$LOG_FILE" 2>/dev/null) || sz=0
            if [ "$sz" -gt 5242880 ]; then
                mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
                printf '[%s] （日志已超过 5MB，旧的已轮转为 %s.1）\n' "$(ts)" "$LOG_FILE" \
                    >> "$LOG_FILE" 2>/dev/null || true
            fi
        fi
    fi
    if [ "$INTERACTIVE" = "1" ] || [ -z "$LOG_FILE" ]; then
        printf '%s\n' "$line"
    fi
}

hr() { log "------------------------------------------------------------"; }

human() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b < 1024) { printf "%d B", b; exit }
        split("B KB MB GB TB PB", u, " ");
        i = 1;
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf "%.1f %s", b, u[i]
    }' 2>/dev/null || printf '%s B' "${1:-0}"
}

fmt_int() {
    case "$1" in
        ''|*[!0-9]*) printf '%s' "$1" ;;
        *) printf '%s' "$1" | sed -e ':a' -e 's/\([0-9]\)\([0-9]\{3\}\>\)/\1,\2/' -e 'ta' ;;
    esac
}

# ---------------------------------- 状态 ------------------------------------
status_write() {
    [ -n "$STATUS_FILE" ] || return 0
    local dir tmp now elapsed phase_num speed
    dir=$(dirname "$STATUS_FILE")
    mkdir -p "$dir" 2>/dev/null
    tmp="$STATUS_FILE.tmp.$$"
    now=$(date +%s)
    elapsed=$((now - START_TS))
    [ "$elapsed" -lt 1 ] && elapsed=1
    speed=$((BYTES_DONE / elapsed))

    case "$PHASE" in
        precheck)   phase_num=1 ;;
        structures) phase_num=2 ;;
        enumerate)  phase_num=3 ;;
        copy)       phase_num=4 ;;
        dryrun)     phase_num=5 ;;
        done)       phase_num=6 ;;
        *)          phase_num=0 ;;
    esac

    {
        printf 'state=%s\n' "$STATE"
        printf 'detail=%s\n' "$STATE_DETAIL"
        printf 'phase=%s\n' "$PHASE"
        printf 'phase_num=%s\n' "$phase_num"
        printf 'phase_total=6\n'
        printf 'total=%s\n' "$TOTAL"
        printf 'done=%s\n' "$DONE_N"
        printf 'ok=%s\n' "$OK_N"
        printf 'skipped=%s\n' "$SKIP_N"
        printf 'exists=%s\n' "$EXIST_N"
        printf 'failed=%s\n' "$FAIL_N"
        printf 'bytes_done=%s\n' "$BYTES_DONE"
        printf 'cur_file=%s\n' "$CUR_FILE"
        printf 'cur_size=%s\n' "$CUR_SIZE"
        printf 'cur_copied=%s\n' "$CUR_COPIED"
        printf 'win_bps=%s\n' "$WIN_BPS"
        printf 'speed_bps=%s\n' "$speed"
        printf 'start_ts=%s\n' "$START_TS"
        printf 'end_ts=%s\n' "$([ "$STATE" = "running" ] && echo 0 || echo "$now")"
        printf 'pid=%s\n' "$$"
        printf 'src=%s\n' "$SRC"
        printf 'dst=%s\n' "$DST"
        printf 'min_speed=%s\n' "$MIN_SPEED_MB"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_FILE" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    LAST_STATUS=$now
}

# 复制当前文件时的高频状态刷新（限制在约 4 秒一次）
status_tick() {
    [ -n "$STATUS_FILE" ] || return 0
    local now
    now=$(date +%s)
    [ $((now - LAST_STATUS)) -ge 4 ] && status_write
    return 0
}

# ---------------------------------- 清理 ------------------------------------
on_exit() {
    local rc=$?
    if [ "$STATE" = "running" ]; then
        if [ "$STATE_DETAIL" = "stopped" ]; then
            STATE="stopped"
        elif [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
            STATE="failed"
        else
            STATE="finished"
        fi
    fi
    status_write
    if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        kill -9 "$CURRENT_PID" 2>/dev/null || true
    fi
    # 注意：*.partial 是抢救出来的数据，绝不能在这里删除
    exit "$rc"
}

on_signal() {
    STOP_SIGNAL=1
    PHASE="copy"
    STATE_DETAIL="stopped"
    log "!! 收到停止信号，正在收尾（最多等待 10 秒）..."
    if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        kill -TERM "$CURRENT_PID" 2>/dev/null || true
    fi
}

trap 'on_exit' EXIT
trap 'on_signal' INT TERM HUP

# ---------------------------------- 参数 ------------------------------------
need_value() {
    if [ "$2" -lt 2 ]; then
        printf '参数 %s 缺少取值\n' "$1" >&2
        exit 1
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        # 同时支持 --key=value 与 --key value 两种写法
        case "$1" in
            --*=*)
                local k="${1%%=*}"
                local v="${1#*=}"
                shift
                set -- "$k" "$v" "$@"
                continue
                ;;
        esac
        key="$1"
        case "$key" in
            --src)          need_value "$key" $#; SRC="$2"; shift 2 ;;
            --dst)          need_value "$key" $#; DST="$2"; shift 2 ;;
            --min-speed)    need_value "$key" $#; MIN_SPEED_MB="$2"; shift 2 ;;
            --speed-window) need_value "$key" $#; SPEED_WINDOW="$2"; shift 2 ;;
            --check)        need_value "$key" $#; CHECK_INTERVAL="$2"; shift 2 ;;
            --max-stall)    need_value "$key" $#; MAX_STALL="$2"; shift 2 ;;
            --grace-factor) need_value "$key" $#; GRACE_FACTOR="$2"; shift 2 ;;
            --grace-max)    need_value "$key" $#; GRACE_MAX="$2"; shift 2 ;;
            --grace-small)  need_value "$key" $#; GRACE_SMALL="$2"; shift 2 ;;
            --find-timeout) need_value "$key" $#; FIND_TIMEOUT="$2"; shift 2 ;;
            --log-file)     need_value "$key" $#; LOG_FILE="$2"; shift 2 ;;
            --status-file)  need_value "$key" $#; STATUS_FILE="$2"; shift 2 ;;
            --failed-list)  need_value "$key" $#; FAILED_LIST="$2"; shift 2 ;;
            --skip-existing) SKIP_EXISTING=1; shift ;;
            --dry-run)      DRY_RUN=1; shift ;;
            --sync)         USE_SYNC=1; shift ;;
            --no-sync)      USE_SYNC=0; shift ;;
            --force)        FORCE=1; shift ;;
            --yes)          ASSUME_YES=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            *)              printf '未知参数: %s（用 --help 查看用法）\n' "$key" >&2; exit 1 ;;
        esac
    done
}

usage() {
    sed -n '2,52p' "$0" 2>/dev/null | sed -e 's/^# \{0,1\}//'
}

# 把参数归一化：去掉末尾斜杠、把 Windows 风格的反斜杠转成斜杠
normalize_path() {
    local p="$1"
    p="${p//\\//}"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

# 逻辑规范化路径（不解引用符号链接），用于"目标是否在源内"的判断
canon_path() {
    local p="$1" out="" seg
    local IFS='/'
    p=$(normalize_path "$p")
    set -f          # 关闭通配符展开，避免路径里的 * ? 被当成 glob
    set -- $p
    set +f
    for seg in "$@"; do
        case "$seg" in
            ''|.) ;;
            ..)   out="${out%/*}"; [ -z "$out" ] && out="" ;;
            *)    if [ -z "$out" ]; then
                      if [ "${p#/}" != "$p" ]; then out="/$seg"; else out="$seg"; fi
                  else
                      out="$out/$seg"
                  fi ;;
        esac
    done
    [ -z "$out" ] && out="/"
    printf '%s' "$out"
}

path_within() { # $1 base, $2 path
    case "$2" in
        "$1") return 0 ;;
        "$1"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------- 数值与容量 ------------------------------
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

free_kb() {
    local path="$1" avail
    avail=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4; exit}')
    is_uint "$avail" || avail=0
    printf '%s' "$avail"
}

dev_of() {
    df -P "$1" 2>/dev/null | awk 'NR==2 {print $1; exit}'
}

file_size() {
    local s
    s=$(stat -c %s "$1" 2>/dev/null) || s=""
    is_uint "$s" || s=0
    printf '%s' "$s"
}

src_size_of() {
    local s
    s=$(stat -c %s "$1" 2>/dev/null) || s=""
    is_uint "$s" && printf '%s' "$s"
}

kill_pid() { # $1 pid, $2 grace seconds
    local pid="$1" wait_s="${2:-5}" i=0
    kill -TERM "$pid" 2>/dev/null || return 1
    while [ "$i" -lt "$wait_s" ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
        i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
    return 0
}

# ---------------------------------- 复制核心 --------------------------------
# 在后台用 dd 复制，按采样窗口读取 dd 报告的累计字节数，
# 用「窗口速度」和「总平均速度」的较小值判定卡死。
# 返回: 0 成功 / 1 出错 / 2 卡死或被用户停止
copy_file() {
    local src="$1" dst="$2"
    local size ddpid rc=0 t0 elapsed curr abps
    local grace ddlog last_part sample
    local dd_flags progress_flag

    ddlog="/tmp/.diskrescue-dd.$$"
    : > "$ddlog" 2>/dev/null

    size=$(src_size_of "$src")
    [ -n "$size" ] || size=0
    CUR_SIZE=$size
    CUR_COPIED=0
    PARTIAL_FILE=""
    LAST_BEAT=0

    # 采样间隔：保证一个统计窗口内有 3~30 个采样点
    sample=$CHECK_INTERVAL
    [ "$sample" -lt 1 ] && sample=1
    [ "$sample" -gt 10 ] && sample=10
    if [ $((SPEED_WINDOW / sample)) -lt 3 ] && [ "$SPEED_WINDOW" -ge 3 ]; then
        sample=$((SPEED_WINDOW / 3))
        [ "$sample" -lt 1 ] && sample=1
    fi

    # 宽限期：宽限期内不判定卡死，避免"慢但正常"的大文件被误杀。
    #   宽限 = 倍数 × (文件大小 / 阈值速度)，并按上限/小文件规则收口。
    grace=0
    if [ "$MIN_SPEED_MB" -gt 0 ]; then
        grace=$(( GRACE_FACTOR * (size / (MIN_SPEED_MB * 1048576)) ))
        [ "$grace" -gt "$GRACE_MAX" ] && grace=$GRACE_MAX
        if [ "$size" -gt 0 ] && [ "$size" -lt 4194304 ]; then
            grace=$GRACE_SMALL
        fi
        [ "$grace" -lt "$GRACE_SMALL" ] && grace=$GRACE_SMALL
        # 至少攒满一个统计窗口，否则"最近 N 秒平均"无法计算
        [ "$grace" -lt "$SPEED_WINDOW" ] && grace=$SPEED_WINDOW
    fi

    dd_flags="bs=1M"
    [ "$USE_SYNC" = "1" ] && dd_flags="$dd_flags conv=fsync"
    progress_flag="status=progress"
    if ! dd --help 2>&1 | grep -q 'status='; then
        progress_flag=""
    fi

    # shellcheck disable=SC2086
    nice -n 10 dd if="$src" of="$dst" $dd_flags $progress_flag 2> "$ddlog" &
    ddpid=$!
    CURRENT_PID=$ddpid

    t0=$(now_ms)
    last_part=0
    WIN_BPS=0
    local -a wt=() wb=()
    local low=0 win_bps span elapsed_ms abps size_hint

    while kill -0 "$ddpid" 2>/dev/null; do
        sleep "$sample"
        kill -0 "$ddpid" 2>/dev/null || break

        # 用户点了停止：先礼后兵，最多等 10 秒
        if [ "$STOP_SIGNAL" = "1" ]; then
            local w=0
            kill -TERM "$ddpid" 2>/dev/null
            while [ "$w" -lt 20 ] && kill -0 "$ddpid" 2>/dev/null; do
                sleep 0.5
                w=$((w + 1))
            done
            kill -KILL "$ddpid" 2>/dev/null
            rc=2
            break
        fi

        # 读 dd 报告的累计字节数
        last_part=0
        if [ -s "$ddlog" ]; then
            last_part=$(tail -n 1 "$ddlog" 2>/dev/null | sed -n 's/^\([0-9][0-9]*\) bytes.*/\1/p')
        fi
        case "$last_part" in ''|*[!0-9]*) last_part=0 ;; esac
        curr=$last_part
        # dd 不支持 status=progress（BusyBox）时，退回用目标文件大小估进度
        if [ "$curr" -le 0 ] && [ -f "$dst" ]; then
            curr=$(file_size "$dst")
        fi
        if [ "$size" -gt 0 ] && [ "$curr" -gt "$size" ]; then
            curr=$size
        fi

        elapsed_ms=$(( $(now_ms) - t0 ))
        [ "$elapsed_ms" -lt 1 ] && elapsed_ms=1
        elapsed=$((elapsed_ms / 1000))
        [ "$elapsed" -lt 1 ] && elapsed=1

        # 记录样本，并丢掉统计窗口之外的旧样本（至少保留 2 个）
        wt+=("$elapsed")
        wb+=("$curr")
        while [ "${#wt[@]}" -gt 2 ] && [ $((elapsed - wt[0])) -gt "$SPEED_WINDOW" ]; do
            wt=("${wt[@]:1}")
            wb=("${wb[@]:1}")
        done

        span=$((elapsed - wt[0]))
        if [ "$span" -lt 1 ]; then
            span=1
            win_bps=0
        else
            win_bps=$(( (curr - wb[0]) / span ))
        fi
        [ "$win_bps" -lt 0 ] && win_bps=0
        WIN_BPS=$win_bps
        abps=$((curr * 1000 / elapsed_ms))
        CUR_COPIED=$curr
        status_tick

        # 心跳日志：每 10 秒一条
        local now_s
        now_s=$(date +%s)
        if [ $((now_s - LAST_BEAT)) -ge 10 ]; then
            log "    ↳ 进度 $(human "$curr") / $(human "$size")，最近 ${span}s 平均 $(human "$win_bps")/s，总体 $(human "$abps")/s"
            LAST_BEAT=$now_s
        fi

        if [ "$MIN_SPEED_MB" -le 0 ]; then
            low=0
            continue
        fi
        if [ "$elapsed" -lt "$grace" ]; then
            low=0
            continue
        fi
        # 窗口至少要攒到 80%，否则样本不足不下结论
        if [ $((span * 10)) -lt $((SPEED_WINDOW * 8)) ]; then
            low=0
            continue
        fi

        if [ "$win_bps" -lt $((MIN_SPEED_MB * 1048576)) ]; then
            low=$((low + 1))
            log "    ! 最近 ${span}s 平均 $(human "$win_bps")/s，低于阈值 ${MIN_SPEED_MB}MB/s（第 ${low}/${MAX_STALL} 次）"
            if [ "$low" -ge "$MAX_STALL" ]; then
                log "    ! 判定卡死，放弃该文件（已读数据会保留为 .partial）"
                kill_pid "$ddpid" 5
                rc=2
                break
            fi
        else
            low=0
        fi
    done

    if [ "$rc" = "0" ]; then
        wait "$ddpid"
        rc=$?
    else
        wait "$ddpid" 2>/dev/null
    fi
    CURRENT_PID=""

    # 外部 TERM（WebGUI 的“停止”）可能让 dd 以非 0 退出，统一按“用户停止”处理
    if [ "$STOP_SIGNAL" = "1" ]; then
        rc=2
    fi

    # dd 结束后的最终字节数（比采样更准确）
    if [ -s "$ddlog" ]; then
        last_part=$(tail -n 1 "$ddlog" 2>/dev/null | sed -n 's/^\([0-9][0-9]*\) bytes.*/\1/p')
        case "$last_part" in ''|*[!0-9]*) last_part=0 ;; esac
        [ "$last_part" -gt 0 ] && CUR_COPIED=$last_part
    fi
    rm -f "$ddlog" 2>/dev/null

    if [ "$rc" = "2" ] || [ "$STOP_SIGNAL" = "1" ]; then
        # 保留已抢救出的部分数据，便于之后用 ddrescue 续读
        if [ -s "$dst" ]; then
            PARTIAL_FILE="$dst.partial"
            mv -f "$dst" "$PARTIAL_FILE" 2>/dev/null || rm -f "$dst"
            log "    ↳ 已保留部分数据: $PARTIAL_FILE（$(human "$(file_size "$PARTIAL_FILE")")）"
        else
            rm -f "$dst" 2>/dev/null
        fi
        return 2
    fi

    if [ "$rc" -ne 0 ]; then
        if [ -s "$dst" ]; then
            PARTIAL_FILE="$dst.partial"
            mv -f "$dst" "$PARTIAL_FILE" 2>/dev/null || rm -f "$dst"
            log "    ↳ dd 读取中断，已保留部分数据: $PARTIAL_FILE（$(human "$(file_size "$PARTIAL_FILE")")）"
        else
            rm -f "$dst" 2>/dev/null
        fi
        return 1
    fi

    if [ ! -f "$dst" ]; then
        log "    ! 目标文件未生成"
        return 1
    fi

    # 保留时间戳/权限/属主（等价于 cp -p）。
    # dd 已经写过一遍数据，这里用 mv + cp -p + mv 的方式复制本地元数据，
    # 避免再整份读一遍源文件（坏盘上每多读一次都是风险）。
    local tmpmeta="$dst.dr-meta.$$"
    if mv -f "$dst" "$tmpmeta" 2>/dev/null; then
        if cp -p -- "$src" "$dst" 2>/dev/null; then
            rm -f "$tmpmeta" 2>/dev/null
        else
            rm -f "$dst" 2>/dev/null
            mv -f "$tmpmeta" "$dst" 2>/dev/null
            log "    ! 保留元数据失败，已保留数据文件（时间戳可能不准）"
        fi
    else
        log "    ! 保留元数据失败，已保留数据文件（时间戳可能不准）"
    fi

    # 大小校验只做提示：FUSE 共享、稀疏文件都可能出现“报告大小不一致”，
    # 但 dd 已成功返回 0，说明数据读到结尾了，不应当作失败。
    if [ "$size" -gt 0 ]; then
        local got
        got=$(file_size "$dst")
        if [ "$got" -ne "$size" ]; then
            log "    ! 提示: 源 $(human "$size") / 目标 $(human "$got") 大小不一致（若为稀疏文件属正常）"
        fi
    fi

    return 0
}

# ---------------------------------- 交互模式 --------------------------------
list_candidates() {
    local d
    for d in /mnt/*; do
        [ -d "$d" ] || continue
        [ "$d" = "/mnt/user0" ] && continue
        [ -d "$d" ] || continue
        printf '  %-28s %s\n' "$d" "$(df -h "$d" 2>/dev/null | awk 'NR==2 {printf "可用 %s / 共 %s", $4, $2}')"
    done
}

ask_paths() {
    INTERACTIVE=1
    printf '\n可用的 /mnt 挂载点：\n'
    list_candidates
    printf '\n'
    while :; do
        if ! read -r -p "请输入需要抢救的【源文件夹】完整路径: " SRC; then
            printf '\n错误: 没有可读的标准输入。非交互使用时请用 --src/--dst 参数。\n' >&2
            exit 1
        fi
        [ -n "$SRC" ] && break
        printf '路径不能为空\n'
    done
    while :; do
        if ! read -r -p "请输入【目标文件夹】完整路径: " DST; then
            printf '\n错误: 没有可读的标准输入。非交互使用时请用 --src/--dst 参数。\n' >&2
            exit 1
        fi
        [ -n "$DST" ] && break
        printf '路径不能为空\n'
    done
    read -r -p "最低平均速度 MB/s（默认 ${MIN_SPEED_MB}，0=关闭）: " ans || true
    is_uint "$ans" && MIN_SPEED_MB=$ans
    read -r -p "统计窗口秒（默认 ${SPEED_WINDOW}）: " ans || true
    is_uint "$ans" && [ "$ans" -gt 0 ] && SPEED_WINDOW=$ans
    read -r -p "宽限倍数（默认 ${GRACE_FACTOR}，宽限=${GRACE_FACTOR}×文件大小/阈值）: " ans || true
    is_uint "$ans" && [ "$ans" -gt 0 ] && GRACE_FACTOR=$ans
    sanitize_numbers
}

confirm() {
    if [ "$ASSUME_YES" = "1" ] || [ "$INTERACTIVE" != "1" ]; then
        return 0
    fi
    local ans
    read -r -p "确认开始？(y/N) " ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# 参数合法性收口：非法或越界时回退到安全默认值，避免除以 0 / 死循环
sanitize_numbers() {
    is_uint "$MIN_SPEED_MB" || MIN_SPEED_MB=10
    [ "$MIN_SPEED_MB" -gt 10240 ] && MIN_SPEED_MB=10240

    is_uint "$SPEED_WINDOW" || SPEED_WINDOW=10
    [ "$SPEED_WINDOW" -lt 2 ] && SPEED_WINDOW=2
    [ "$SPEED_WINDOW" -gt 3600 ] && SPEED_WINDOW=3600

    is_uint "$CHECK_INTERVAL" || CHECK_INTERVAL=2
    [ "$CHECK_INTERVAL" -lt 1 ] && CHECK_INTERVAL=1
    [ "$CHECK_INTERVAL" -gt 60 ] && CHECK_INTERVAL=60
    [ "$CHECK_INTERVAL" -gt "$SPEED_WINDOW" ] && CHECK_INTERVAL=$SPEED_WINDOW

    is_uint "$MAX_STALL" || MAX_STALL=1
    [ "$MAX_STALL" -lt 1 ] && MAX_STALL=1
    [ "$MAX_STALL" -gt 100 ] && MAX_STALL=100

    is_uint "$GRACE_FACTOR" || GRACE_FACTOR=2
    [ "$GRACE_FACTOR" -gt 100 ] && GRACE_FACTOR=100

    is_uint "$GRACE_MAX" || GRACE_MAX=900
    [ "$GRACE_MAX" -lt 5 ] && GRACE_MAX=5
    [ "$GRACE_MAX" -gt 86400 ] && GRACE_MAX=86400

    is_uint "$GRACE_SMALL" || GRACE_SMALL=10
    [ "$GRACE_SMALL" -lt 1 ] && GRACE_SMALL=1
    [ "$GRACE_SMALL" -gt 3600 ] && GRACE_SMALL=3600

    is_uint "$FIND_TIMEOUT" || FIND_TIMEOUT=120
    [ "$FIND_TIMEOUT" -lt 5 ] && FIND_TIMEOUT=5
}

# ---------------------------------- 主流程 ----------------------------------
# WebGUI 通过 PHP 启动本脚本时，脚本会继承 PHP 的响应管道等文件描述符。
# 长跑任务若一直持有这些 fd，浏览器端会一直等“开始抢救”的响应直到任务结束，
# 所以非交互模式下主动关闭从调用者继承的 fd（>2），只保留 0/1/2。
detach_inherited_fds() {
    [ -n "$LOG_FILE" ] || return 0
    [ -d /proc/$$/fd ] || return 0
    local f n nums=""
    for f in /proc/$$/fd/*; do
        n=${f##*/}
        case "$n" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$n" -gt 2 ]; then
            nums="$nums $n"
        fi
    done
    for n in $nums; do
        eval "exec ${n}>&-" 2>/dev/null || true
    done
    return 0
}

main() {
    parse_args "$@"
    detach_inherited_fds
    sanitize_numbers

    if [ -z "$SRC" ] || [ -z "$DST" ]; then
        ask_paths
    fi

    SRC=$(normalize_path "$SRC")
    DST=$(normalize_path "$DST")

    # ---- 启动前检查 ----
    PHASE="precheck"
    status_write

    if [ ! -d "$SRC" ]; then
        STATE="failed"; STATE_DETAIL="源目录不存在或无法访问"
        log "错误: 源目录不存在: $SRC"
        return 1
    fi
    if [ ! -r "$SRC" ]; then
        STATE="failed"; STATE_DETAIL="源目录不可读"
        log "错误: 源目录不可读: $SRC"
        return 1
    fi
    if [ -z "$DST" ]; then
        STATE="failed"; STATE_DETAIL="目标目录无效"
        log "错误: 目标目录无效"
        return 1
    fi

    local csrc cdst
    # 统一成无尾斜杠的规范路径，后续 ${file#"$SRC"/} 才能正确剥离前缀
    csrc=$(canon_path "$SRC")
    cdst=$(canon_path "$DST")
    if [ "$csrc" = "$cdst" ]; then
        STATE="failed"; STATE_DETAIL="源目录与目标目录相同"
        log "错误: 源目录与目标目录相同，无法复制"
        return 1
    fi
    if path_within "$csrc" "$cdst"; then
        STATE="failed"; STATE_DETAIL="目标目录位于源目录内部"
        log "错误: 目标目录位于源目录内部（$cdst 在 $csrc 下），会导致递归复制"
        return 1
    fi
    SRC="$csrc"

    # 不允许把整个 /mnt 或共享根当源，避免误扫全部磁盘
    case "$SRC" in
        /mnt|/mnt/user|/mnt/user0|/mnt/disks|/mnt/remotes)
            STATE="failed"; STATE_DETAIL="源目录范围过大"
            log "错误: 源目录不能是 $SRC，请选择具体的子目录（例如 /mnt/disk1/xxx）"
            return 1
            ;;
    esac

    # 软链接可能绕过字面路径比较，再用真实路径检查一次
    local rsrc rdst
    rsrc=$(realpath -m "$SRC" 2>/dev/null || printf '%s' "$SRC")
    rdst=$(realpath -m "$DST" 2>/dev/null || printf '%s' "$DST")
    if [ -n "$rsrc" ] && [ "$rsrc" = "$rdst" ]; then
        STATE="failed"; STATE_DETAIL="源与目标实际是同一个目录"
        log "错误: 源与目标实际是同一个目录（$rsrc）"
        return 1
    fi
    if [ -n "$rsrc" ] && path_within "$rsrc" "$rdst"; then
        STATE="failed"; STATE_DETAIL="目标实际位于源目录内部"
        log "错误: 目标实际位于源目录内部（软链接），已拒绝"
        return 1
    fi

    if [ ! -d "$DST" ]; then
        log "目标目录不存在，正在创建: $DST"
        if ! mkdir -p "$DST"; then
            STATE="failed"; STATE_DETAIL="无法创建目标目录"
            log "错误: 无法创建目标目录: $DST"
            return 1
        fi
    fi

    local sdev ddev
    sdev=$(dev_of "$SRC")
    ddev=$(dev_of "$DST")
    if [ -n "$sdev" ] && [ "$sdev" = "$ddev" ]; then
        log "警告: 源与目标在同一文件系统（$sdev），这会增加坏盘负担，且不是真正的备份。"
    fi

    local avail
    avail=$(free_kb "$DST")
    if [ "$avail" -gt 0 ]; then
        log "目标可用空间: $(human $((avail * 1024)))"
        if [ "$avail" -lt 2097152 ] && [ "$FORCE" != "1" ]; then
            STATE="failed"; STATE_DETAIL="目标空间不足（小于 2GB）"
            log "错误: 目标空间不足 2GB。如确认继续，请加 --force"
            return 1
        fi
    fi

    if [ -z "$FAILED_LIST" ]; then
        FAILED_LIST="$DST/disk-rescue-failed.txt"
    fi
    mkdir -p "$(dirname "$FAILED_LIST")" 2>/dev/null || true
    printf '# disk-rescue 失败清单  %s\n# 源: %s\n# 格式: 时间 | 原因 | 源文件\n' \
        "$(ts)" "$SRC" >> "$FAILED_LIST" 2>/dev/null || true

    log "============================================================"
    log "Unraid 坏盘数据抢救工具（速度监控版）"
    log "源目录  : $SRC"
    log "目标目录: $DST"
    if [ "$DRY_RUN" = "1" ]; then
        log "模式    : 预扫描（只读，不复制）"
    else
        log "复制引擎: dd (bs=1M$( [ "$USE_SYNC" = "1" ] && printf ', conv=fsync' ))"
    fi
    if [ "$MIN_SPEED_MB" -gt 0 ]; then
        log "速度监控: 最近 ${SPEED_WINDOW}s 平均低于 ${MIN_SPEED_MB}MB/s 则跳过（连续 ${MAX_STALL} 次判定，每 ${CHECK_INTERVAL}s 采样）"
        log "宽限规则: ${GRACE_FACTOR} × (文件大小/阈值)，上限 ${GRACE_MAX}s，小文件 ${GRACE_SMALL}s"
    else
        log "速度监控: 已关闭"
    fi
    log "失败清单: $FAILED_LIST"
    log "============================================================"

    if [ "$DRY_RUN" != "1" ] && ! confirm; then
        STATE="stopped"; STATE_DETAIL="用户取消"
        log "已取消。"
        return 0
    fi

    # ---- 1. 建目录结构 ----
    PHASE="structures"
    status_write
    hr
    log ">>> 1/4 创建目录结构..."
    local dirs_file derr_file dcount
    dirs_file="/tmp/.diskrescue-dirs.$$"
    derr_file="/tmp/.diskrescue-dirserr.$$"
    : > "$dirs_file"; : > "$derr_file"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$FIND_TIMEOUT" find "$SRC" -type d -print0 > "$dirs_file" 2> "$derr_file" &
    else
        find "$SRC" -type d -print0 > "$dirs_file" 2> "$derr_file" &
    fi
    local dfind_pid=$! frc=0
    while kill -0 "$dfind_pid" 2>/dev/null; do
        sleep 1
        if [ "$STOP_SIGNAL" = "1" ]; then
            kill -TERM "$dfind_pid" 2>/dev/null
            break
        fi
    done
    wait "$dfind_pid" 2>/dev/null
    frc=$?
    dcount=0
    while IFS= read -r -d '' dir; do
        [ "$dir" = "$SRC" ] && continue
        local rel="${dir#"$SRC"/}"
        [ "$rel" = "$dir" ] && continue
        if ! mkdir -p "$DST/$rel" 2>/dev/null && [ ! -d "$DST/$rel" ]; then
            log "    ! 无法创建目录: $rel"
        fi
        dcount=$((dcount + 1))
        [ $((dcount % 2000)) -eq 0 ] && log "    ...已创建 $dcount 个目录"
    done < "$dirs_file"
    rm -f "$dirs_file"
    if [ "$frc" = "124" ]; then
        log "    警告: 目录枚举超时（${FIND_TIMEOUT}s），目录结构可能不完整，继续执行"
    elif [ "$frc" -ne 0 ]; then
        log "    警告: 目录枚举返回 $frc（磁盘可能有坏道），已创建 $dcount 个目录"
    fi
    if [ -s "$derr_file" ]; then
        log "    枚举期间的错误（最多显示 20 条）:"
        head -n 20 "$derr_file" | while IFS= read -r line; do log "      $line"; done
    fi
    rm -f "$derr_file"
    log "目录结构创建完毕（$dcount 个目录）。"

    # ---- 2. 枚举文件 ----
    PHASE="enumerate"
    status_write
    hr
    log ">>> 2/4 枚举文件（坏盘上可能较慢，页面会持续更新计数）..."
    local list_file ferr_file fcount
    list_file="/tmp/.diskrescue-list.$$"
    ferr_file="/tmp/.diskrescue-finderr.$$"
    : > "$list_file"; : > "$ferr_file"

    # find 放到后台跑，前台每 3 秒统计一次“已经找到多少个文件”，
    # 这样即使某个目录卡住，界面也能看到进度而不是一直停在“枚举中”。
    if command -v timeout >/dev/null 2>&1; then
        timeout "$FIND_TIMEOUT" find "$SRC" -type f -print0 > "$list_file" 2> "$ferr_file" &
    else
        find "$SRC" -type f -print0 > "$list_file" 2> "$ferr_file" &
    fi
    local find_pid=$!
    local ticks=0
    while kill -0 "$find_pid" 2>/dev/null; do
        sleep 1
        ticks=$((ticks + 1))
        # 每 3 秒统计并上报一次，既能显示进度又不刷屏
        if [ $((ticks % 3)) -eq 0 ]; then
            local c
            c=$(tr -dc '\0' < "$list_file" 2>/dev/null | wc -c)
            is_uint "$c" && TOTAL=$c
            status_write
            log "    ...已找到 $(fmt_int "$TOTAL") 个文件"
        fi
        if [ "$STOP_SIGNAL" = "1" ]; then
            kill -TERM "$find_pid" 2>/dev/null
            break
        fi
    done
    wait "$find_pid" 2>/dev/null
    frc=$?
    if [ "$frc" = "124" ]; then
        log "错误: 文件枚举超时（${FIND_TIMEOUT}s），请调大 --find-timeout 或先修复磁盘"
        STATE="failed"; STATE_DETAIL="文件枚举超时"
        return 1
    fi
    if [ -s "$ferr_file" ]; then
        log "枚举期间的错误（最多显示 20 条）:"
        head -n 20 "$ferr_file" | while IFS= read -r line; do log "      $line"; done
    fi
    rm -f "$ferr_file"

    local fsize
    fsize=$(stat -c %s "$list_file" 2>/dev/null) || fsize=0
    if [ "$fsize" -le 0 ]; then
        TOTAL=0
        log "源目录中没有找到文件，结束。"
        STATE="finished"
        PHASE="done"
        return 0
    fi
    fcount=$(tr -dc '\0' < "$list_file" 2>/dev/null | wc -c)
    is_uint "$fcount" || fcount=0
    TOTAL=$fcount
    log "共找到 $(fmt_int $TOTAL) 个文件。"

    if [ "$DRY_RUN" = "1" ]; then
        PHASE="dryrun"
        log ">>> 3/4 预扫描（只读校验每个文件头部）..."
        local n=0 bad=0
        while IFS= read -r -d '' file; do
            if [ "$STOP_SIGNAL" = "1" ]; then
                log "已收到停止信号，预扫描中止。"
                break
            fi
            n=$((n + 1))
            DONE_N=$n
            CUR_FILE="${file#"$SRC"/}"
            local sz
            sz=$(src_size_of "$file")
            if [ -z "$sz" ]; then
                bad=$((bad + 1))
                printf '%s | 无法读取大小 | %s\n' "$(ts)" "$file" >> "$FAILED_LIST" 2>/dev/null || true
                log "[$n/$TOTAL] 无法读取: $CUR_FILE"
            elif [ "$sz" -gt 0 ]; then
                if ! dd if="$file" of=/dev/null bs=1M count=1 iflag=fullblock 2>/dev/null; then
                    bad=$((bad + 1))
                    printf '%s | 首 1MB 读取失败 | %s\n' "$(ts)" "$file" >> "$FAILED_LIST" 2>/dev/null || true
                    log "[$n/$TOTAL] 读取失败: $CUR_FILE"
                fi
            fi
            if [ $((n % 10)) -eq 0 ]; then status_write; fi
        done < "$list_file"
        FAIL_N=$bad
        DONE_N=$TOTAL
        log "预扫描完成：$(fmt_int $TOTAL) 个文件，$(fmt_int $bad) 个存在读取问题。"
        rm -f "$list_file"
        PHASE="done"
        STATE="finished"
        hr
        log "预扫描结束。未复制任何文件。"
        return 0
    fi

    # ---- 3. 复制 ----
    PHASE="copy"
    status_write
    hr
    log ">>> 3/4 开始复制（可以随时点“停止”）。"
    hr

    local n=0 rc reason psz
    while IFS= read -r -d '' file; do
        if [ "$STOP_SIGNAL" = "1" ]; then
            log "已收到停止信号，剩余文件不再处理。"
            break
        fi

        n=$((n + 1))
        DONE_N=$((n - 1))
        CUR_FILE="${file#"$SRC"/}"
        CUR_SIZE=0
        CUR_COPIED=0

        local rel dfile
        rel="$CUR_FILE"
        dfile="$DST/$rel"
        log "[$n/$(fmt_int $TOTAL)] $rel"

        if [ ! -e "$file" ]; then
            reason="无法 stat（文件可能已消失或磁盘无法读取）"
            FAIL_N=$((FAIL_N + 1))
            DONE_N=$n
            printf '%s | %s | %s\n' "$(ts)" "$reason" "$file" >> "$FAILED_LIST" 2>/dev/null || true
            log "    ❌ 跳过: $reason"
            continue
        fi

        if [ "$SKIP_EXISTING" = "1" ] && [ -f "$dfile" ]; then
            local ssz dsz
            ssz=$(file_size "$file"); dsz=$(file_size "$dfile")
            if [ "$ssz" -gt 0 ] && [ "$ssz" = "$dsz" ]; then
                log "    ⏭  目标已存在且大小一致，跳过"
                EXIST_N=$((EXIST_N + 1))
                DONE_N=$n
                continue
            fi
        fi

        # 清理上次运行留下的同名目标文件
        if [ -e "$dfile" ] && [ "${dfile%.partial}" = "$dfile" ]; then
            rm -f "$dfile" 2>/dev/null
        fi
        rm -f "$dfile.partial" 2>/dev/null

        copy_file "$file" "$dfile"
        rc=$?
        case "$rc" in
            0)
                OK_N=$((OK_N + 1))
                local sz
                sz=$(file_size "$dfile")
                BYTES_DONE=$((BYTES_DONE + sz))
                log "    ✅ 成功（$(human "$sz")）"
                ;;
            2)
                if [ "$STOP_SIGNAL" = "1" ]; then
                    reason="用户停止（已保留 .partial）"
                else
                    SKIP_N=$((SKIP_N + 1))
                    reason="速度低于 ${MIN_SPEED_MB}MB/s 或卡死，已跳过"
                fi
                # 已抢救出的字节也算进“已复制”，报表更真实
                psz=0
                [ -f "$dfile.partial" ] && psz=$(file_size "$dfile.partial")
                BYTES_DONE=$((BYTES_DONE + psz))
                printf '%s | %s | %s\n' "$(ts)" "$reason" "$file" >> "$FAILED_LIST" 2>/dev/null || true
                log "    ⏹  中断（$reason）"
                ;;
            1)
                FAIL_N=$((FAIL_N + 1))
                reason="读取错误"
                psz=0
                [ -f "$dfile.partial" ] && psz=$(file_size "$dfile.partial")
                BYTES_DONE=$((BYTES_DONE + psz))
                printf '%s | %s | %s\n' "$(ts)" "$reason" "$file" >> "$FAILED_LIST" 2>/dev/null || true
                log "    ❌ 失败（$reason）"
                ;;
            *)
                FAIL_N=$((FAIL_N + 1))
                reason="未知错误 rc=$rc"
                printf '%s | %s | %s\n' "$(ts)" "$reason" "$file" >> "$FAILED_LIST" 2>/dev/null || true
                log "    ❌ 失败（$reason）"
                ;;
        esac

        DONE_N=$n
        CUR_FILE=""
        status_tick
    done < "$list_file"

    rm -f "$list_file"

    # ---- 4. 汇总 ----
    PHASE="done"
    hr
    log ">>> 4/4 汇总"
    log "总计: $(fmt_int $TOTAL)    成功: $(fmt_int $OK_N)    已存在: $(fmt_int $EXIST_N)    跳过: $(fmt_int $SKIP_N)    失败: $(fmt_int $FAIL_N)    已复制: $(human "$BYTES_DONE")"

    if [ "$STOP_SIGNAL" = "1" ]; then
        STATE="stopped"
        STATE_DETAIL="用户停止"
        log "已被用户停止。"
    elif [ "$FAIL_N" -gt 0 ] || [ "$SKIP_N" -gt 0 ]; then
        STATE="finished"
        STATE_DETAIL="有文件未成功"
        log "⚠️ 注意：有文件未能拷贝成功！"
        log "失败/跳过清单: $FAILED_LIST"
        log "对于 .partial 文件，可尝试: ddrescue -r3 '<源文件>' '<.partial 文件>'"
    else
        STATE="finished"
        STATE_DETAIL="全部成功"
        log "🎉 全部文件拷贝成功。"
    fi
    hr

    if [ "$STOP_SIGNAL" = "1" ]; then
        return 2
    fi
    if [ "$FAIL_N" -gt 0 ] || [ "$SKIP_N" -gt 0 ]; then
        return 3
    fi
    return 0
}

main "$@"
