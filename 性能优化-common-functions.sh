#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════
#  真我GT8 SukiSU 温控移除模块 v2.0 —— 公共函数库
#
#  策略（由强到弱，参考 HORAE Extreme 思路重构）：
#    1. emul_temp 温度欺骗：让温控引擎读到低温，达不到任何阈值 → 不限频
#       这是主手段，比"停服务 / 清配置"温和且有效
#    2. 安装时改写 OPPO/realme 私有温控配置阈值（customize.sh）
#    3. 归零 cooling_device、解锁 CPU/GPU 频率上限
#    4. 兜底：停用 thermal 相关 init 服务（默认关闭）
#
#  ══ 资源归属声明（v2.8）══════════════════════════════════════
#  本模块独占以下资源。改动任何一项前，先确认没有引入第二个写入方 ——
#  温控类模块互相覆盖时「最后执行者获胜」，故障现象随机且难以复现。
#
#    · /sys/class/thermal/thermal_zone*/emul_temp   唯一写入方（5s 周期重放）
#    · /sys/class/thermal/cooling_device*/cur_state 仅在 UNLOCK_CDEV=1 时写，
#      且永久跳过显示/背光类节点（见 is_display_cdev）
#    · /sys/devices/system/cpu/cpu*/cpufreq/scaling_{max,min}_freq
#    · /sys/class/kgsl/kgsl-3d0/{max_pwrlevel,max_gpu_clk,max_clock_mhz}
#    · /proc/shell-temp                             仅 OPPO_SHELL_TEMP=1 时写
#    · /proc/oplus-votable/GAUGE_UPDATE             仅 OPPO_GAUGE=1 时写
#    · horae 服务（dumpsys horae testmode）         仅 HORAE_TESTMODE=1 时调用
#    · vendor.oplus.ormsHalService-aidl-default     仅 DISABLE_ORMS=1 时停
#    · patched/thermal、patched/extra bind mount    由 mount_config_overlays 独占
#
#  ══ 单一轮询点约束（v2.8）════════════════════════════════════
#  所有周期性行为必须挂在 service.sh 的那一个 while 循环里。
#  不要为单个功能新开 `while true` / `( sleep N; ... ) &` —— 多一个循环就多一处
#  互相覆盖与 fork 开销的来源。开机 60s 的自检也已并进主循环（VERIFY_TICK）。
# ═══════════════════════════════════════════════════════════════

MODDIR="${MODDIR:-${0%/*}}"
# 兜底：上层没传且 ${0%/*} 拿不到目录时，退回标准安装路径
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
PERSIST_DIR="/data/adb/thermal_remove"
SYSFS_BAK="$PERSIST_DIR/sysfs.bak"
PROP_BAK="$PERSIST_DIR/prop.bak"
MOUNT_LIST="$PERSIST_DIR/mounts.list"
STATE_FILE="$PERSIST_DIR/state"
LOG_FILE="$PERSIST_DIR/thermal_remove.log"
# 欺骗记账（v2.8.2）：apply_spoof 每次写成功的温感记成 dir|value 一行。
# 判定「是否欺骗中」必须以它为准 —— 部分厂商内核 set_emul_temp 走驱动私有
# 路径，sysfs 回读 emul_temp 恒为 0，回读判定的结果是「欺骗实际生效但
# 全部被判成未欺骗」（实机：欺骗中显示 0、真实温度探测从未被触发）。
SPOOF_LIST="$PERSIST_DIR/spoof.list"
# v2.8.11：oplus_vrr_config.json 里 hw_nit_limit 等字段的原厂值（安装期写入）
VRR_BASE="$PERSIST_DIR/vrr_baseline.list"
# v2.8.8：inputflinger 线程提权 —— 原 nice 值备份（tid|原nice）与「已处理进程」标记。
# 备份用来精确还原（而不是一刀切写回 0）：线程的原始 nice 未必是 0。
TOUCH_BAK="$PERSIST_DIR/touch_thread.bak"
TOUCH_MARK="$PERSIST_DIR/.touch_thread.pid"

MODE_CONF="$MODDIR/mode.conf"
SPOOF_CONF="$MODDIR/spoof.conf"
GAME_LIST="$MODDIR/game_list.conf"
PROTECT_LIST="$MODDIR/protect_list.conf"

POLL_SECONDS=5
RES_SPOOF_TICKS=6          # 状态不变时，每 6 个周期补写一次欺骗值
VERIFY_TICK=12             # 开机后第 12 个 tick 做一次欺骗校验（5s × 12 ≈ 60s）

# 冲突检测库：纯函数、零副作用。安装期的 customize.sh 会单独 source 同一份实现，
# 保证「安装期告警」与「运行时诊断」用的是同一套判定规则。
MODULES_DIR="${MODULES_DIR:-/data/adb/modules}"
SELF_ID="${SELF_ID:-realme-gt8-sukisu-thermal-remove}"
. "$MODDIR/common/conflicts.sh" 2>/dev/null

mkdir -p "$PERSIST_DIR" 2>/dev/null
[ -f "$LOG_FILE" ] || : > "$LOG_FILE"
[ "$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')" -gt 262144 ] 2>/dev/null && : > "$LOG_FILE"

# ── 系统版本 ──────────────────────────────────────────────────
ANDROID_REL="$(getprop ro.build.version.release 2>/dev/null)"
ANDROID_SDK="$(getprop ro.build.version.sdk 2>/dev/null)"
IS_A16=0
[ -n "$ANDROID_SDK" ] && [ "$ANDROID_SDK" -ge 36 ] 2>/dev/null && IS_A16=1

# ── 日志 ──────────────────────────────────────────────────────
log_print() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ── 冲突自检：把命中的其他温控模块写进日志（只记录，不改任何状态）──
log_conflicts() {
    [ "$CHECK_CONFLICTS" = "1" ] || return 0
    command -v detect_conflicts >/dev/null 2>&1 || return 0
    _c=$(detect_conflicts 2>/dev/null)
    if [ -z "$_c" ]; then
        log_print "✓ 冲突自检：未检测到其他温控模块"
        return 0
    fi
    echo "$_c" | while IFS='|' read -r _id _nm _ver _rk _nt; do
        [ -n "$_id" ] && log_print "⚠ 冲突模块[$_rk]: $_nm ($_id) $_ver — $_nt"
    done
}

# ── 配置项读取（KEY=VALUE，支持 # 注释与引号）──────────────────
# v2.8.4：去壳改用纯 shell 实现（_strip），省掉两次 sed + 一个管道。
# 语义与原 sed 三段式严格等价（尾部空白 → 首双引号 → 尾双引号），
# 已用 6 组边界值（含空值/纯空白/内嵌引号/前后空格）对拍验证。
_strip() {
    _sv="$1"
    while :; do
        case "$_sv" in
            *" ") _sv="${_sv% }" ;;
            *"	") _sv="${_sv%	}" ;;
            *) break ;;
        esac
    done
    case "$_sv" in '"'*) _sv="${_sv#\"}" ;; esac
    case "$_sv" in *'"') _sv="${_sv%\"}" ;; esac
}

# 单键读取：只跑一次 sed，取值+去壳都在 shell 内完成
conf_get() {
    _f="$1"; _k="$2"; _d="$3"
    _v=$(sed -n "s/^$_k=//p" "$_f" 2>/dev/null | head -n 1)
    if [ -n "$_v" ]; then
        _strip "$_v"
        _v="$_sv"
    fi
    [ -z "$_v" ] && _v="$_d"
    echo "$_v"
}

load_conf() {
    # v2.8.12 性能：原实现 25 次 conf_get = 25×(sed+head) = 50 次 fork，
    # 每轮主循环（5s）跑一次 → 一天约 86 万次 fork，只为读一份几乎不变的配置。
    # 现改为纯 shell 一次遍历：read 是内建命令，赋值走 case 白名单（不用 eval，避免注入）。
    # 行为保持：只取**第一次**出现的键（与原 sed -n 's/^k=//p' | head -1 一致），
    # 空值回落到默认值；行尾空白与首尾引号处理沿用 _strip。

    MODE=dynamic
    GAME_PROTECT=0; STOP_SERVICES=0; UNLOCK_FREQ=1; OPPO_SHELL_TEMP=0
    OPPO_GAUGE=0; HORAE_TESTMODE=0; DISABLE_ORMS=0; TOUCH_BOOST=1
    TOUCH_THREAD_BOOST=0; TOUCH_THREAD_NICE=-19
    PATCH_THERMAL=1; PATCH_EXTRA=0
    UNLOCK_CDEV=0
    DISPLAY_PROTECT=1
    CHECK_CONFLICTS=1
    SCAN_RESOURCES=0
    REPLACE_ENCRYPTED=0

    SOC_T=29500; SKIN_T=29500; CAM_T=29500; BATT_T=29500
    SPOOF_BATT=0; SHELL_PROC_T=29500; BLACKLIST=""

    _lc_seen=""
    for _lc_f in "$MODE_CONF" "$SPOOF_CONF"; do
        [ -f "$_lc_f" ] || continue
        # 注意 `|| [ -n "$_lc_ln" ]`：POSIX 下 read 遇到「最后一行没有换行符」
        # 会返回非 0，只用 `while read` 会把该行**整行丢弃**
        # （实测：文件是 "MODE=off" 且无尾换行 → 读不到，回落成 dynamic）。
        # 手工编辑配置很容易不写尾换行，这个兜底必须有。
        while IFS= read -r _lc_ln || [ -n "$_lc_ln" ]; do
            case "$_lc_ln" in ''|'#'*) continue ;; esac
            case "$_lc_ln" in *=*) ;; *) continue ;; esac
            _kk=${_lc_ln%%=*}
            _lc_v=${_lc_ln#*=}
            case " $_lc_seen " in *" $_kk "*) continue ;; esac
            _strip "$_lc_v"
            case "$_kk" in
                MODE)               MODE=$_sv ;;
                GAME_PROTECT)       GAME_PROTECT=$_sv ;;
                STOP_SERVICES)      STOP_SERVICES=$_sv ;;
                UNLOCK_FREQ)        UNLOCK_FREQ=$_sv ;;
                OPPO_SHELL_TEMP)    OPPO_SHELL_TEMP=$_sv ;;
                OPPO_GAUGE)         OPPO_GAUGE=$_sv ;;
                HORAE_TESTMODE)     HORAE_TESTMODE=$_sv ;;
                DISABLE_ORMS)       DISABLE_ORMS=$_sv ;;
                TOUCH_BOOST)        TOUCH_BOOST=$_sv ;;
                TOUCH_THREAD_BOOST) TOUCH_THREAD_BOOST=$_sv ;;
                TOUCH_THREAD_NICE)  TOUCH_THREAD_NICE=$_sv ;;
                PATCH_THERMAL)      PATCH_THERMAL=$_sv ;;
                PATCH_EXTRA)        PATCH_EXTRA=$_sv ;;
                UNLOCK_CDEV)        UNLOCK_CDEV=$_sv ;;
                DISPLAY_PROTECT)    DISPLAY_PROTECT=$_sv ;;
                CHECK_CONFLICTS)    CHECK_CONFLICTS=$_sv ;;
                SCAN_RESOURCES)     SCAN_RESOURCES=$_sv ;;
                REPLACE_ENCRYPTED)  REPLACE_ENCRYPTED=$_sv ;;
                SOC_T)              SOC_T=$_sv ;;
                SKIN_T)             SKIN_T=$_sv ;;
                CAM_T)              CAM_T=$_sv ;;
                BATT_T)             BATT_T=$_sv ;;
                SPOOF_BATT)         SPOOF_BATT=$_sv ;;
                SHELL_PROC_T)       SHELL_PROC_T=$_sv ;;
                BLACKLIST)          BLACKLIST=$_sv ;;
                *) continue ;;
            esac
            _lc_seen="$_lc_seen $_kk"
        done < "$_lc_f"
    done

    case "$MODE" in always|dynamic|off) ;; *) MODE=dynamic ;; esac

    # 空值回落默认（原 conf_get 的 [ -z ] && _d 语义）
    [ -z "$MODE" ]              && MODE=dynamic
    [ -z "$GAME_PROTECT" ]      && GAME_PROTECT=0
    [ -z "$STOP_SERVICES" ]     && STOP_SERVICES=0
    [ -z "$UNLOCK_FREQ" ]       && UNLOCK_FREQ=1
    [ -z "$TOUCH_BOOST" ]       && TOUCH_BOOST=1
    [ -z "$TOUCH_THREAD_BOOST" ] && TOUCH_THREAD_BOOST=0
    [ -z "$TOUCH_THREAD_NICE" ] && TOUCH_THREAD_NICE=-19
    [ -z "$PATCH_THERMAL" ]     && PATCH_THERMAL=1
    [ -z "$DISPLAY_PROTECT" ]   && DISPLAY_PROTECT=1
    [ -z "$CHECK_CONFLICTS" ]   && CHECK_CONFLICTS=1
    [ -z "$SOC_T" ]             && SOC_T=29500
    [ -z "$SKIN_T" ]            && SKIN_T=29500
    [ -z "$CAM_T" ]             && CAM_T=29500
    [ -z "$BATT_T" ]            && BATT_T=29500
    [ -z "$SHELL_PROC_T" ]      && SHELL_PROC_T=29500

    # 显式 return 0：函数末尾是 `[ -z ... ] && ...` 链，条件为假时整条返回 1，
    # 会让调用方拿到「失败」的退出码（无 set -e 时不致命，但契约该干净）。
    return 0
}

# ── sysfs 安全写入：写前备份原值 ──────────────────────────────
# v2.8.4：备份去重改用 awk 做「行首字面量比较」。
# 原实现 grep -q "^$_p=" 把路径当正则：sysfs 路径含大量 '.'（如
# /sys/class/kgsl/kgsl-3d0/…），'.' 会匹配任意字符，可能把不存在的节点
# 误判为已备份 → 真实原值没被记录，卸载时无法还原。
# 注意不能用 grep -F：它不支持 ^ 锚点，"max_freq=" 会子串命中
# "scaling_max_freq="，同样误判。awk 的 index($0,k)==1 才是行首字面量比较。
sysfs_set() {
    _p="$1"; _v="$2"
    [ -e "$_p" ] || return 1
    awk -v k="$_p=" 'index($0,k)==1 { f=1 } END { exit !f }' "$SYSFS_BAK" 2>/dev/null || \
        echo "$_p=$(cat "$_p" 2>/dev/null)" >> "$SYSFS_BAK" 2>/dev/null
    echo "$_v" > "$_p" 2>/dev/null
}

restore_sysfs() {
    [ -f "$SYSFS_BAK" ] || return 0
    while IFS='=' read -r _p _v; do
        [ -n "$_p" ] && [ -e "$_p" ] && echo "$_v" > "$_p" 2>/dev/null
    done < "$SYSFS_BAK"
    : > "$SYSFS_BAK"
    log_print "sysfs 已还原"
}

# ── 判断内核是否支持温度仿真（emul_temp）───────────────────────
spoof_supported() {
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/emul_temp" ] && return 0
    done
    return 1
}

# ── 温感分类 → 目标欺骗温度 ───────────────────────────────────
zone_target() {
    case "$1" in
        *batt*|*battery*|*usb*)        echo "$BATT_T" ;;
        *shell*|*skin*|*case*|*frame*) echo "$SKIN_T" ;;
        *cam*|*tof*|*flash*)           echo "$CAM_T" ;;
        *)                             echo "$SOC_T" ;;
    esac
}

is_blacklisted() {
    [ -z "$BLACKLIST" ] && return 1
    for _b in $BLACKLIST; do
        case "$1" in $_b) return 0 ;; esac
    done
    return 1
}

# ── 应用温度欺骗 ──────────────────────────────────────────────
# 写成功的温感记入 $SPOOF_LIST（dir|value），作为「欺骗中」判定的唯一事实来源。
# 不要改回「回读 emul_temp 判定」—— 见 SPOOF_LIST 上方说明。
apply_spoof() {
    _n=0; _skip=0
    : > "$SPOOF_LIST.tmp" 2>/dev/null
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -f "$_z/temp" ] || continue
        if [ ! -e "$_z/emul_temp" ]; then
            _skip=$((_skip + 1))
            continue
        fi
        _ty=$(cat "$_z/type" 2>/dev/null)
        [ -z "$_ty" ] && _ty=$(basename "$_z")
        is_blacklisted "$_ty" && continue
        case "$_ty" in
            *batt*|*battery*|*usb*)
                [ "$SPOOF_BATT" = "1" ] || continue
                ;;
        esac
        _tv=$(zone_target "$_ty")
        if echo "$_tv" > "$_z/emul_temp" 2>/dev/null; then
            _n=$((_n + 1))
            echo "$_z|$_tv" >> "$SPOOF_LIST.tmp" 2>/dev/null
        fi
    done
    mv -f "$SPOOF_LIST.tmp" "$SPOOF_LIST" 2>/dev/null
    oppo_nodes_on
    log_print "欺骗已应用：$_n 个温感${_skip:+，$_skip 个不支持 emul_temp}"
    echo "$_n"
}

# ── 撤销温度欺骗（写 0 = 关闭仿真，恢复真实读数）───────────────
restore_spoof() {
    _n=0
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/emul_temp" ] || continue
        echo 0 > "$_z/emul_temp" 2>/dev/null && _n=$((_n + 1))
    done
    oppo_nodes_off
    : > "$SPOOF_LIST" 2>/dev/null
    log_print "欺骗已撤销：$_n 个温感"
}

# ── OPPO/realme 私有接口 ──────────────────────────────────────
oppo_nodes_on() {
    if [ "$OPPO_SHELL_TEMP" = "1" ] && [ -e /proc/shell-temp ]; then
        _i=0
        while [ "$_i" -le 9 ]; do
            echo "$_i $SHELL_PROC_T" > /proc/shell-temp 2>/dev/null
            _i=$((_i + 1))
        done
    fi
    if [ "$OPPO_GAUGE" = "1" ] && [ -d /proc/oplus-votable/GAUGE_UPDATE ]; then
        _gu=/proc/oplus-votable/GAUGE_UPDATE
        chmod 666 "$_gu/force_val" 2>/dev/null
        echo 1000 > "$_gu/force_val" 2>/dev/null
        chmod 666 "$_gu/force_active" 2>/dev/null
        echo 1 > "$_gu/force_active" 2>/dev/null
    fi
}

oppo_nodes_off() {
    if [ "$OPPO_GAUGE" = "1" ] && [ -d /proc/oplus-votable/GAUGE_UPDATE ]; then
        echo 0 > /proc/oplus-votable/GAUGE_UPDATE/force_active 2>/dev/null
    fi
}

# ── lock_val：写入后立即 chmod -w，阻止用户态守护进程改回 ────────
#    （来自 Extreme GT；只用于 GPU 节点，不用于 emul_temp 以免影响内核仿真管理）
lock_val() {
    _v="$1"; _p="$2"
    [ -e "$_p" ] || return 1
    umount "$_p" 2>/dev/null
    chmod +w "$_p" 2>/dev/null
    echo "$_v" > "$_p" 2>/dev/null
    _rc=$?
    chmod -w "$_p" 2>/dev/null
    command -v restorecon >/dev/null 2>&1 && restorecon -R -F "$_p" >/dev/null 2>&1
    return $_rc
}

# ── GPU 解锁：用 INT_MAX 表示"不限制" ──────────────────────────
unlock_gpu() {
    lock_val 0 /sys/class/kgsl/kgsl-3d0/max_pwrlevel
    lock_val 2147483647 /sys/class/kgsl/kgsl-3d0/max_gpu_clk
    lock_val 2147483647 /sys/class/kgsl/kgsl-3d0/max_clock_mhz
}

# ── 触控服务提优先级（改善跟手性）──────────────────────────────
touch_boost() {
    [ "$TOUCH_BOOST" = "1" ] || return 0
    for _n in vendor-oplus-hardware-touch-V2-service touchDaemon; do
        _pid=$(pidof "$_n" 2>/dev/null)
        [ -n "$_pid" ] && renice -n -19 -p "$_pid" 2>/dev/null
    done
}

# ── 触控：inputflinger 线程级提权（v2.8.8）────────────────────
#  为什么需要：上面的 touch_boost 只把厂商触控守护进程 renice 到 -19，
#  但事件分发并不在那两个进程里 —— 它在 inputflinger 的
#  InputReader（读事件）/ InputDispatcher（分发）/ InputClassifier（手势判定）
#  线程上。也就是说厂商服务提权了，交给系统之后的那半程还是默认优先级。
#
#  为什么只到 renice 为止（重要，不要"优化"成实时优先级）：
#    · SCHED_FIFO 不可抢占。评审过的两个第三方包用 chrt -f -p 99 把输入/SF
#      设成 FIFO，再叠加 sched_rt_throttle_us=0（RT 任务唯一的保险丝）——
#      任一 RT 线程死循环就是整机硬卡死，只能长按电源。
#    · 本模块不碰 sched_rt_throttle_us，也不用 chrt -f。
#  nice 值的代价可控：只影响 CFS 调度权重，不产生不可抢占路径；
#  进程重启自动失效，且这里存了原值可精确还原。
#
#  幂等：优先级设置随线程生命周期有效，同一个 inputflinger 实例只做一次，
#  主循环 5 秒一轮不会反复 renice（用 TOUCH_MARK 记录已处理的 pid）。

# 读线程当前 nice：/proc/<tid>/stat 第 19 字段。
# comm 字段可能含空格和括号，因此取**最后一个** ') ' 之后的内容再分词；
# 剩下第 1 个字段是 state（原第 3 字段），nice = 19 - 2 = 第 17 个。
tb_nice_of() {
    [ -r "/proc/$1/stat" ] || return 1
    IFS= read -r _tns < "/proc/$1/stat" 2>/dev/null || return 1
    _tns=${_tns##*') '}
    set -- $_tns
    [ $# -ge 17 ] || return 1
    shift 16
    echo "$1"
}

# 列出待提权的线程 tid：comm **精确匹配**，不做前缀/子串匹配（避免误伤同名服务）
touch_thread_list() {
    _tlp="$1"
    [ -n "$_tlp" ] && [ -d "/proc/$_tlp/task" ] || return 0
    for _td in "/proc/$_tlp"/task/*; do
        _tid=${_td##*/}
        case "$_tid" in ''|*[!0-9]*) continue ;; esac
        _c=$(cat "$_td/comm" 2>/dev/null) || continue
        case "$_c" in
            InputReader|InputDispatcher|InputClassifier) echo "$_tid" ;;
        esac
    done
}

touch_thread_boost() {
    # 开关被关掉时负责收尾：把此前提过的线程还原回去（这样 WebUI 上关掉开关
    # 也能在 5 秒内生效，不必等重启）
    if [ "$TOUCH_THREAD_BOOST" != "1" ]; then
        [ -f "$TOUCH_MARK" ] && touch_thread_restore
        return 0
    fi
    _tb_pid=$(pidof -s inputflinger 2>/dev/null)
    [ -n "$_tb_pid" ] || return 0
    # 同一进程实例已处理过 → 直接返回（优先级在该进程存活期间持续有效）
    [ "$(cat "$TOUCH_MARK" 2>/dev/null)" = "$_tb_pid" ] && return 0
    # pid 变了说明进程重启过：旧 tid 已失效，先按备份尽力还原，再重新记账
    touch_thread_restore
    : > "$TOUCH_BAK" 2>/dev/null
    _tb_n=0
    for _tid in $(touch_thread_list "$_tb_pid"); do
        _old=$(tb_nice_of "$_tid") || continue
        renice -n "$TOUCH_THREAD_NICE" -p "$_tid" >/dev/null 2>&1 || continue
        echo "$_tid|$_old" >> "$TOUCH_BAK" 2>/dev/null
        _tb_n=$((_tb_n + 1))
    done
    echo "$_tb_pid" > "$TOUCH_MARK" 2>/dev/null
    [ "$_tb_n" -gt 0 ] && \
        log_print "触控线程提权：inputflinger(pid=$_tb_pid) $_tb_n 个线程 → nice $TOUCH_THREAD_NICE"
    return 0
}

touch_thread_restore() {
    # 无备份也无标记 → 从未提过权，直接返回（主循环每 5 秒会走到这里）
    [ -s "$TOUCH_BAK" ] || [ -f "$TOUCH_MARK" ] || return 0
    _tr_n=0
    if [ -s "$TOUCH_BAK" ]; then
        while IFS='|' read -r _tid _old; do
            [ -n "$_tid" ] || continue
            [ -d "/proc/$_tid" ] || continue
            renice -n "$_old" -p "$_tid" >/dev/null 2>&1 && _tr_n=$((_tr_n + 1))
        done < "$TOUCH_BAK"
    fi
    : > "$TOUCH_BAK" 2>/dev/null
    rm -f "$TOUCH_MARK" 2>/dev/null
    [ "$_tr_n" -gt 0 ] && log_print "触控线程优先级已还原：$_tr_n 个线程"
    return 0
}

# 诊断用：打印 inputflinger 三个线程的当前 nice（验证是否真的提权成功）
touch_status() {
    _ts_p=$(pidof -s inputflinger 2>/dev/null)
    if [ -z "$_ts_p" ]; then
        echo "  inputflinger 进程未找到（Android 12+ 才有独立进程；"
        echo "  更老的版本里这些线程跑在 system_server 内，本开关不适用）"
        return 0
    fi
    echo "  inputflinger pid=$_ts_p  开关 TOUCH_THREAD_BOOST=$TOUCH_THREAD_BOOST"
    echo "  已记账线程: $(grep -c . "$TOUCH_BAK" 2>/dev/null) 个"
    for _td in "/proc/$_ts_p"/task/*; do
        _tid=${_td##*/}
        case "$_tid" in ''|*[!0-9]*) continue ;; esac
        _c=$(cat "$_td/comm" 2>/dev/null)
        case "$_c" in InputReader|InputDispatcher|InputClassifier) ;; *) continue ;; esac
        printf '    %-16s tid=%-7s nice=%s\n' "$_c" "$_tid" "$(tb_nice_of "$_tid")"
    done
}

# ── 等用户数据解锁（比 sys.boot_completed 更靠后，服务才就绪）────
wait_until_login() {
    _i=0
    until [ -d /data/data/android ] || [ "$_i" -gt 300 ]; do
        sleep 1
        _i=$((_i + 1))
    done
}

# ── OPPO HORAE 系统服务的 testmode ────────────────────────────
oppo_horae_testmode() {
    [ "$HORAE_TESTMODE" = "1" ] || return 0
    command -v dumpsys >/dev/null 2>&1 || return 0
    dumpsys horae testmode >/dev/null 2>&1
}

# ── 校验欺骗是否真的生效 ──────────────────────────────────────
#  v2.8.5 修复：原实现必然误判失败，有三个独立缺陷 ——
#    1) **期望值来源错位**：拿 SHELL_PROC_T（/proc/shell-temp 的值）当期望值，
#       但 emul_temp 欺骗写的是 thermal_zone（皮肤类用 SKIN_T），而
#       /proc/shell-temp 只在 OPPO_SHELL_TEMP=1 时才写（默认 0，从未写过）
#       → 比对的期望值本身就是错的
#    2) **行首匹配过严**：grep '^Temp:' 要求行首，厂商输出常带缩进或前缀
#    3) **小数位假设**：用 %.2f 固定两位，'Temp:29.5' / 'Temp:29500' 都会判失败
#
#  现在：以模块自身记账 SPOOF_LIST 为事实来源（与 v2.8.2 判定原则一致），
#  dumpsys horae 只作辅助参考，且格式兼容；失败时把原因写进日志。
verify_spoof() {
    # ① 主判据：记账清单里有记录 = 欺骗已应用（写入时逐条记的，不依赖回读）
    if [ -s "$SPOOF_LIST" ]; then
        return 0
    fi
    # ② 记账为空：可能是没应用，也可能是记账丢失 → 交由日志说明
    return 1
}

# 诊断用：把 horae 的实际输出与期望值一并记录，便于定位「为什么没生效」。
# 只在 verify_and_recover 里调用一次，不进主循环。
verify_spoof_detail() {
    _vd_out=$(dumpsys horae 2>/dev/null | grep -i 'temp' | head -n 3)
    if [ -z "$_vd_out" ]; then
        log_print "  校验详情: dumpsys horae 无 Temp 相关输出（该 ROM 可能不提供此字段）"
    else
        log_print "  校验详情: horae 读到 [$(echo "$_vd_out" | tr '\n' ' ')]"
    fi
    log_print "  期望: 皮肤温感被欺骗为 ${SKIN_T} 毫摄氏度"
    if [ "$OPPO_SHELL_TEMP" != "1" ]; then
        log_print "  提示: OPPO_SHELL_TEMP=0，/proc/shell-temp 未写入（该路径不参与校验）"
    fi
    log_print "  记账: $(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ') 条记录"
}

# ── 属性写入（带原值备份，可还原）──────────────────────────────
# v2.8.4：同 sysfs_set，改用 awk 行首字面量比较（属性名含 '.'，
# 例如 persist.sys.orms.name，正则 '.' 会匹配任意字符而误判已备份）。
prop_set() {
    _k="$1"; _v="$2"
    awk -v k="$_k=" 'index($0,k)==1 { f=1 } END { exit !f }' "$PROP_BAK" 2>/dev/null || \
        echo "$_k=$(getprop "$_k" 2>/dev/null)" >> "$PROP_BAK" 2>/dev/null
    setprop "$_k" "$_v" 2>/dev/null
    command -v resetprop >/dev/null 2>&1 && resetprop "$_k" "$_v" 2>/dev/null
}

restore_props() {
    [ -f "$PROP_BAK" ] || return 0
    while IFS='=' read -r _k _v; do
        [ -n "$_k" ] && setprop "$_k" "$_v" 2>/dev/null
    done < "$PROP_BAK"
    : > "$PROP_BAK"
    log_print "属性已还原"
}

# ── OPPO ORMS（资源/温控管理）停用 ────────────────────────────
orms_off() {
    [ "$DISABLE_ORMS" = "1" ] || return 0
    setprop ctl.stop vendor.oplus.ormsHalService-aidl-default 2>/dev/null
    prop_set persist.sys.orms.name ""
}

orms_on() {
    restore_props
    setprop ctl.start vendor.oplus.ormsHalService-aidl-default 2>/dev/null
}

# ── 挂载安装时生成的配置改写（bind mount，可用开关控制）─────────
#    SKIP_MOUNT=1 时跳过（post-fs-data 早期阶段调用 apply_state 用）
#    $1 = "$MODDIR/patched/thermal" 或 "$MODDIR/patched/extra"
mount_set() {
    _root="$1"
    [ -d "$_root" ] || return 0
    find "$_root" -type f 2>/dev/null | while IFS= read -r _src; do
        _dst="${_src#$_root}"
        [ -f "$_dst" ] || continue
        # 已挂载则只补记录，不重复叠加。
        # v2.8.4：用 awk 精确比较挂载点字段（$2），替代 grep -q " $_dst "。
        # 原因：grep 把 $_dst 当正则，路径里的 '.' 会匹配任意字符 ——
        # /a/b.xml 会被已挂载的 /a/bXxml 误判为「已挂载」而跳过 bind，
        # 导致该配置静默不生效。awk 做的是字符串相等比较。
        if awk -v d="$_dst" '$2==d { found=1 } END { exit !found }' /proc/mounts 2>/dev/null; then
            grep -qxF "$_dst" "$MOUNT_LIST" 2>/dev/null || echo "$_dst" >> "$MOUNT_LIST"
            continue
        fi
        mount --bind "$_src" "$_dst" 2>/dev/null || continue
        echo "$_dst" >> "$MOUNT_LIST"
        log_print "mount: $_dst"
    done
}

mount_config_overlays() {
    if [ "${SKIP_MOUNT:-0}" = "1" ]; then
        log_print "早期阶段跳过配置挂载 (SKIP_MOUNT=1)"
        return 0
    fi
    : > "$MOUNT_LIST" 2>/dev/null
    [ "$PATCH_THERMAL" = "1" ] && mount_set "$MODDIR/patched/thermal"
    [ "$PATCH_EXTRA"   = "1" ] && mount_set "$MODDIR/patched/extra"
    log_print "配置改写挂载完成 (thermal=$PATCH_THERMAL extra=$PATCH_EXTRA)"
}

unmount_config_overlays() {
    [ -f "$MOUNT_LIST" ] || return 0
    while IFS= read -r _dst; do
        [ -n "$_dst" ] && umount "$_dst" 2>/dev/null
    done < "$MOUNT_LIST"
    : > "$MOUNT_LIST"
    log_print "配置改写已卸载"
}

# ── 停用 thermal 相关 init 服务（兜底手段，默认关闭）────────────
stop_thermal_services() {
    for _s in $(getprop | sed -n 's/.*\[init\.svc\.\([^]]*\)\].*/\1/p' | grep -i thermal | sort -u); do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    for _s in thermal-engine thermal thermald \
              vendor.thermal-engine vendor.thermal vendor.thermald \
              vendor.thermal-hal-2-0 thermal-hal-2-0 vendor.thermal-hal-1-1 \
              vendor.thermal-hal-aidl thermal-hal-aidl vendor.thermal-hal-3-0 \
              vendor.thermal_service vendor.thermalserviced \
              mi_thermald vendor.oplus_thermald oplus_thermald vendor.oppo_thermal ; do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    if [ "$IS_A16" = "1" ]; then
        for _s in vendor.perfd vendor.perfservice vendor.adpf \
                  vendor.thermal-mitigation thermal-mitigation ; do
            setprop ctl.stop "$_s" 2>/dev/null
        done
    fi
}

# ── 归零 cooling_device + 解锁频率 ────────────────────────────
#    ⚠ v2.3 起 cooling_device 归零默认关闭（UNLOCK_CDEV=0）：
#      强制把显示/背光类冷却节点写成 0 会把屏幕亮度压到最低
#      （2026-10-03 实机反馈：亮度锁最低，手动调亮亮一下又被压回去）
#      欺骗生效时内核不会抬升 cur_state，归零属于冗余且有害的"霰弹"手段
DISPLAY_CDEV_PATTERN="*display* *disp* *bright* *backlight* *lcd* *oled* *panel* *screen* *bl-*"
is_display_cdev() {
    _t=""
    read -r _t < "${1%/*}/type" 2>/dev/null
    [ -z "$_t" ] && _t="${1%/*}"
    for _p in $DISPLAY_CDEV_PATTERN; do
        case "$_t" in $_p) return 0 ;; esac
    done
    return 1
}

# 把曾被动过的 cooling_device 还原回原始值（升级到 UNLOCK_CDEV=0 时执行一次）
restore_cdev_once() {
    [ "$UNLOCK_CDEV" = "1" ] && return 0
    [ -f "$PERSIST_DIR/.cdev_restored" ] && return 0
    [ -f "$SYSFS_BAK" ] || { : > "$PERSIST_DIR/.cdev_restored"; return 0; }
    while IFS='=' read -r _p _v; do
        case "$_p" in
            */cooling_device*/cur_state)
                [ -e "$_p" ] && echo "$_v" > "$_p" 2>/dev/null && \
                    log_print "还原冷却节点: $_p=$_v" ;;
        esac
    done < "$SYSFS_BAK"
    grep -v '/cooling_device.*/cur_state=' "$SYSFS_BAK" > "$SYSFS_BAK.tmp" 2>/dev/null
    mv -f "$SYSFS_BAK.tmp" "$SYSFS_BAK" 2>/dev/null
    : > "$PERSIST_DIR/.cdev_restored"
    log_print "cooling_device 已全部还原（UNLOCK_CDEV=0）"
}

unlock_perf() {
    [ "$UNLOCK_FREQ" = "1" ] || return 0
    unlock_gpu
    for _cp in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -d "$_cp" ] || continue
        _mx=$(cat "$_cp/cpuinfo_max_freq" 2>/dev/null)
        _mn=$(cat "$_cp/cpuinfo_min_freq" 2>/dev/null)
        [ -n "$_mx" ] && sysfs_set "$_cp/scaling_max_freq" "$_mx"
        [ -n "$_mn" ] && sysfs_set "$_cp/scaling_min_freq" "$_mn"
    done
    for _g in /sys/class/kgsl/kgsl-3d0/devfreq /sys/class/devfreq/*kgsl* /sys/class/devfreq/*gpu*; do
        [ -d "$_g" ] || continue
        _mx=$(tr ' ' '\n' < "$_g/available_frequencies" 2>/dev/null | sort -n | tail -1)
        [ -n "$_mx" ] && sysfs_set "$_g/max_freq" "$_mx"
    done
    # cooling_device 归零：默认关闭，且永远跳过显示/背光类节点
    [ "$UNLOCK_CDEV" = "1" ] || { restore_cdev_once; return 0; }
    for _c in /sys/class/thermal/cooling_device*; do
        [ -e "$_c/cur_state" ] || continue
        if [ "$DISPLAY_PROTECT" = "1" ] && is_display_cdev "$_c/cur_state"; then
            log_print "跳过显示类冷却节点: $_c"
            continue
        fi
        sysfs_set "$_c/cur_state" 0
    done
}

# 内核 thermal core 会周期性写回，需要持续压制
reapply_perf() {
    [ "$UNLOCK_FREQ" = "1" ] || return 0
    [ "$UNLOCK_CDEV" = "1" ] && for _c in /sys/class/thermal/cooling_device*/cur_state; do
        [ -e "$_c" ] || continue
        if [ "$DISPLAY_PROTECT" = "1" ] && is_display_cdev "$_c"; then
            continue
        fi
        echo 0 > "$_c" 2>/dev/null
    done
    # v2.8.12 性能：原实现每个 CPU 调一次 cat + 一次 dirname（8 核 = 16 次 fork），
    # 而且**无条件重写** scaling_max_freq —— 值本来就对的时候这一写毫无意义。
    # 现改为：read 内建读节点（零 fork）、${_f%/*} 取目录（零 fork）、值相同直接跳过写。
    for _f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [ -e "$_f" ] || continue
        _mx=""
        read -r _mx < "${_f%/*}/cpuinfo_max_freq" 2>/dev/null
        [ -n "$_mx" ] || continue
        _cur=""
        read -r _cur < "$_f" 2>/dev/null
        [ "$_cur" = "$_mx" ] && continue
        echo "$_mx" > "$_f" 2>/dev/null
    done
}

# ── 场景检测 ──────────────────────────────────────────────────
get_charging() {
    # v2.8.12 性能：原实现每轮 cat 遍历所有 power_supply 节点（GT8 上 5~8 个）= 5~8 次 fork。
    # read 是 shell 内建命令，重定向读第一行即可，零 fork。
    for _p in /sys/class/power_supply/*/status; do
        [ -f "$_p" ] || continue
        _st=""
        read -r _st < "$_p" 2>/dev/null
        case "$_st" in
            Charging|Full) echo 1; return ;;
        esac
    done
    echo 0
}

get_focus_app() {
    _line=$(dumpsys activity activities 2>/dev/null | grep -m1 'topResumedActivity=')
    if [ -z "$_line" ]; then
        _line=$(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=')
    fi
    [ -z "$_line" ] && { echo ""; return; }
    echo "$_line" | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+/' \
        | head -n 1 | sed 's|/$||'
}

is_in_list() {
    _list="$1"; _app="$2"
    [ -r "$_list" ] || return 1
    [ -z "$_app" ] && return 1
    awk -v app="$_app" -F '#' '{
        gsub(/^[ \t\r]+|[ \t\r]+$/, "", $1)
        if ($1 == app) { found=1; exit }
    } END { exit (found ? 0 : 1) }' "$_list"
}

# ── 决策：是否需要移除温控 ────────────────────────────────────
#    返回 1 = 移除（应用欺骗），0 = 保护（撤销欺骗）
#    $1 = reload（默认 1）：调用前若尚未 load_conf 才需要；传 0 表示
#    「调用方刚刚已 load_conf 过」，跳过重复加载。
#    v2.8.4：此前这里无条件 load_conf，而 service.sh 主循环在调用前已
#    load_conf 一次 → 每 5 秒多付一次全量配置解析（约 20 次 conf_get）。
# v2.8.12 新增：判断列表文件里是否有「有效条目」（非空、非纯注释）。
# 纯 shell 扫描，零 fork（列表只有十几行）。
_has_effective() {
    [ -s "$1" ] || return 1
    # `|| [ -n ]`：列表只有一行且无尾换行时，纯 while read 会读不到。
    while IFS= read -r _he_ln || [ -n "$_he_ln" ]; do
        # 先剥前导空白再判注释 —— 否则「缩进过的注释行」（如 "   # com.foo"）
        # 会被当成有效条目，导致 dumpsys 白跑（实测过）。
        _he_t=$_he_ln
        while :; do
            case "$_he_t" in
                ' '*|'	'*) _he_t=${_he_t#?} ;;
                *) break ;;
            esac
        done
        case "$_he_t" in ''|'#'*) continue ;; esac
        return 0
    done < "$1"
    return 1
}

decide_state() {
    [ "${1:-1}" = "1" ] && load_conf
    [ "$MODE" = "off" ] && { echo 0; return; }
    [ "$MODE" = "always" ] && { echo 1; return; }

    if [ "$(get_charging)" = "1" ]; then
        echo 0; return
    fi

    # v2.8.12 性能：只有「真的可能命中」时才去查前台应用。
    # 原实现无条件调用 get_focus_app —— 而它跑的是 dumpsys activity activities，
    # 一个输出数百 KB 的重型 Binder 调用，每 5 秒一次（一天 1.7 万次）。
    # 默认配置下 protect_list.conf 全是注释、GAME_PROTECT=0，查出来的包名根本没人用。
    # 加这道闸后，「没配保护/游戏列表」的用户彻底不再触发 dumpsys。
    if _has_effective "$PROTECT_LIST" || \
       { [ "$GAME_PROTECT" = "1" ] && _has_effective "$GAME_LIST"; }; then
        _app=$(get_focus_app)
        if [ -n "$_app" ]; then
            is_in_list "$PROTECT_LIST" "$_app" && { echo 0; return; }
            if [ "$GAME_PROTECT" = "1" ] && is_in_list "$GAME_LIST" "$_app"; then
                echo 0; return
            fi
        fi
    fi
    echo 1
}

# ── 应用 / 撤销主逻辑 ─────────────────────────────────────────
apply_state() {
    _want="$1"
    _cur=$(cat "$STATE_FILE" 2>/dev/null)

    if [ "$_want" = "1" ]; then
        [ "$STOP_SERVICES" = "1" ] && stop_thermal_services
        orms_off
        mount_config_overlays
        unlock_perf
        oppo_horae_testmode
        touch_boost
        touch_thread_boost
        apply_spoof > /dev/null
        [ "$_cur" = "on" ] || log_print "→ 温控已移除 (mode=$MODE)"
        echo "on" > "$STATE_FILE"
    else
        restore_spoof > /dev/null
        unmount_config_overlays
        restore_sysfs
        # v2.8.8：温控保护期间也把输入线程优先级还原（提权与去温控同属「性能模式」）
        touch_thread_restore
        rm -f "$PERSIST_DIR/.cdev_restored"
        orms_on
        [ "$_cur" = "off" ] || log_print "→ 温控已恢复 (mode=$MODE)"
        echo "off" > "$STATE_FILE"
    fi
}

# ── 打印各温感当前温度 ────────────────────────────────────────
# v2.8.5：「（欺骗）」标记改用记账 SPOOF_LIST 判定，不再回读 emul_temp ——
# 部分厂商内核回读恒 0（写入却生效），回读判定会让所有温感都不显示欺骗标记。
# ── v2.8.11：读 VRR 亮度字段的安装期基线 ───────────────────────
# 返回 $1 键的基线值；基线文件不存在时返回空（调用方据此选择不报警）。
vrr_baseline_get() {
    [ -f "$VRR_BASE" ] || return 0
    while IFS='=' read -r _bk _bv; do
        [ "$_bk" = "$1" ] && { printf '%s' "$_bv"; return 0; }
    done < "$VRR_BASE"
}

dump_temp() {
    _dt_sl=" $(cat "$SPOOF_LIST" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/temp" ] || continue
        _t=$(cat "$_z/temp" 2>/dev/null)
        _ty=$(cat "$_z/type" 2>/dev/null)
        case "$_t" in ''|*[!0-9-]*) continue ;; esac
        if [ "${#_t}" -gt 4 ]; then _d=$((_t / 1000)); else _d="$_t"; fi
        _m=""
        case "$_dt_sl" in *"$_z|"*) _m="（欺骗）" ;; esac
        echo "  ${_ty:-zone}: ${_d}°C$_m"
    done
}

# ── 打印全部冷却设备（诊断亮度问题用）──────────────────────────
dump_cdev() {
    for _c in /sys/class/thermal/cooling_device*; do
        [ -e "$_c/cur_state" ] || continue
        _ty=$(cat "$_c/type" 2>/dev/null)
        _skip=""
        is_display_cdev "$_c/cur_state" && _skip=" ⚠显示类(已保护)"
        printf "  %-16s type=%-22s cur=%-4s max=%-4s%s\n" \
            "$(basename "$_c")" "${_ty:-?}" \
            "$(cat "$_c/cur_state" 2>/dev/null)" \
            "$(cat "$_c/max_state" 2>/dev/null)" "$_skip"
    done
}
