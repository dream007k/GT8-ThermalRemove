# GT8 ThermalRemove · common/perf.sh
# 频率锁 / GPU 解锁 / 冷却设备 / 触控提权 / 温控服务停止
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


# ── lock_val：写入后立即 chmod -w，阻止用户态守护进程改回 ────────
#    （来自 Extreme GT；只用于 GPU 节点，不用于 emul_temp 以免影响内核仿真管理）
#
# v2.9.2 修复（真实缺陷）：原实现 chmod -w 之后，**既不备份原值也不记录被锁节点**。
# 后果有两条，都很实在：
#   1. 卸载模块 / 关掉 UNLOCK_GPU 后，kgsl 节点仍是只读、值仍是解锁后的值 ——
#      节点要等重启才恢复，而重启后模块若没自动加载，用户会看到「GPU 频率被锁死」。
#   2. restore_sysfs 走的是备份文件，而这些节点从未进过备份，所以还原路径压根不覆盖它们。
# 现在：首次锁定时把「原值」记进 LOCK_BAK（复用 sysfs_set 的备份链，不需要另立
# 机制），并把节点路径记进 LOCKED_NODES；restore_locked_nodes 负责 chmod +w 后
# 写回原值。首次锁定判定用 LOCK_BAK 里是否已有该路径，和 sysfs_set 的索引同源。
LOCK_BAK="$PERSIST_DIR/gpu_lock.bak"
LOCKED_NODES="$PERSIST_DIR/gpu_locked.list"

lock_val() {
    _v="$1"; _p="$2"
    [ -e "$_p" ] || return 1
    umount "$_p" 2>/dev/null
    chmod +w "$_p" 2>/dev/null
    # 首次锁定才备份原值（后续重复调用不覆盖，否则会把改过的值当成原值）
    if ! grep -qF "$_p=" "$LOCK_BAK" 2>/dev/null; then
        _lv_orig=""
        read -r _lv_orig < "$_p" 2>/dev/null
        [ -n "$_lv_orig" ] && echo "$_p=$_lv_orig" >> "$LOCK_BAK" 2>/dev/null
    fi
    grep -qxF "$_p" "$LOCKED_NODES" 2>/dev/null || echo "$_p" >> "$LOCKED_NODES" 2>/dev/null
    echo "$_v" > "$_p" 2>/dev/null
    _rc=$?
    chmod -w "$_p" 2>/dev/null
    command -v restorecon >/dev/null 2>&1 && restorecon -R -F "$_p" >/dev/null 2>&1
    return $_rc
}

# 还原 lock_val 锁过的节点：先 chmod +w 解除只读，再写回原值。
# 在 restore_sysfs 之后调用（那时备份文件已清空，正好靠 LOCK_BAK 独立还原）。
restore_locked_nodes() {
    [ -f "$LOCK_BAK" ] || return 0
    while IFS='=' read -r _lp _lv; do
        [ -n "$_lp" ] || continue
        [ -e "$_lp" ] || continue
        chmod +w "$_lp" 2>/dev/null
        echo "$_lv" > "$_lp" 2>/dev/null
    done < "$LOCK_BAK"
    : > "$LOCK_BAK"
    : > "$LOCKED_NODES"
    log_info "GPU 频锁节点已解除只读并还原原值"
    return 0
}

# ── GPU 解锁：用 INT_MAX 表示"不限制" ──────────────────────────
# v2.8.13 功耗优化：新增 UNLOCK_GPU 独立开关 + GPU_MAX_CLK 甜点值。
#   · UNLOCK_GPU=0   → 完全不碰 GPU，只解锁 CPU（发热/耗电显著下降）
#   · GPU_MAX_CLK    → 频率上限（Hz）。默认 2147483647=不限制（原满血行为）；
#                      设甜点值（如 800000000=800MHz）可在性能与发热间折中。
#   ⚠ 单位假设 Hz，且 max_gpu_clk / max_clock_mhz 是 HORAE 继承的 legacy 接口，
#     SM8750 上真正生效的可能是 devfreq（见 unlock_perf / reapply_perf 里的
#     gpu_cap_target_into）。改完用 §验证命令确认哪个节点真的把频率压下来了。
# 计算 devfreq 目标档位：available_frequencies 里 ≤ GPU_MAX_CLK 的最大档；
# 上限设得过低（无档位满足）时回退到最低档，保证 GPU 至少可用。
#   $1 = available_frequencies 文件；结果写全局变量 _GCAP
gpu_cap_target_into() {
    _GCAP=""; _g_max=""; _g_min=""
    while IFS= read -r _afl || [ -n "$_afl" ]; do
        # 循环变量用 _gv（不叫 _f，避免与调用方外层 for _f 冲突）
        for _gv in $_afl; do
            case "$_gv" in ''|*[!0-9]*) continue ;; esac
            if [ -z "$_g_max" ] || [ "$_gv" -gt "$_g_max" ]; then _g_max=$_gv; fi
            if [ -z "$_g_min" ] || [ "$_gv" -lt "$_g_min" ]; then _g_min=$_gv; fi
            if [ "$_gv" -le "$GPU_MAX_CLK" ]; then
                if [ -z "$_GCAP" ] || [ "$_gv" -gt "$_GCAP" ]; then _GCAP=$_gv; fi
            fi
        done
    done < "$1" 2>/dev/null
    [ -n "$_GCAP" ] || _GCAP=$_g_min
    return 0
}

unlock_gpu() {
    # v2.9.2：关开关时把之前 lock_val 锁过的节点解锁并还原原值。
    # 原实现直接 return，导致「1 → 0」切换后节点仍是只读、值仍是解锁后的状态，
    # 用户只能靠重启恢复。现在切关即还原。
    if [ "$UNLOCK_GPU" != "1" ]; then
        restore_locked_nodes
        return 0
    fi
    lock_val 0 /sys/class/kgsl/kgsl-3d0/max_pwrlevel
    lock_val "$GPU_MAX_CLK" /sys/class/kgsl/kgsl-3d0/max_gpu_clk
    if [ "$GPU_MAX_CLK" = "2147483647" ]; then
        lock_val 2147483647 /sys/class/kgsl/kgsl-3d0/max_clock_mhz
    else
        lock_val $((GPU_MAX_CLK / 1000000)) /sys/class/kgsl/kgsl-3d0/max_clock_mhz
    fi
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
        # v2.8.13 省电：read 内建替代 cat（inputflinger 有 20+ 线程 = 20+ 次 fork）
        _c=""
        read -r _c < "$_td/comm" 2>/dev/null || continue
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
        log_info "触控线程提权：inputflinger(pid=$_tb_pid) $_tb_n 个线程 → nice $TOUCH_THREAD_NICE"
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
    [ "$_tr_n" -gt 0 ] && log_info "触控线程优先级已还原：$_tr_n 个线程"
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

# ── 停用 thermal 相关 init 服务（兜底手段，默认关闭）────────────
# ── v2.12.0：按进程名取 PID（跨 ps 实现的正确写法）────────────────
# 原实现直接 `ps -A | awk '$NF == n { print $2 }'`，把「PID 在第 2 列」当成事实 ——
# 那是 toybox ps 的列序；busybox ps 的列序是 `PID USER TIME COMMAND`（PID 在第 1 列），
# 于是 $2 拿到 USER 名，kill 收到非数字参数静默报错 → STOP_SERVICES 对 perf 守护
# 进程完全失效且无任何提示（不误杀，属功能降级）。
# 现在两级：① 优先 pidof（toybox/busybox 语义一致，无列序假设）；
#           ② 退回 ps 时**按表头找 PID 列**，不硬编码列号。
pid_of_name() {
    _pn="$1"
    [ -n "$_pn" ] || return 0
    _po=$(pidof "$_pn" 2>/dev/null)
    if [ -n "$_po" ]; then printf '%s' "$_po"; return 0; fi
    ps -A 2>/dev/null | awk -v n="$_pn" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "PID") c = i; next }
        c && $NF == n { printf "%s ", $c }'
    return 0
}

stop_thermal_services() {
    for _s in $(getprop | sed -n 's/.*\[init\.svc\.\([^]]*\)\].*/\1/p' | grep -i thermal | sort -u); do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    for _s in thermal-engine thermal-engine-v2 thermal thermald \
              vendor.thermal-engine vendor.thermal vendor.thermald \
              vendor.thermal-hal-2-0 thermal-hal-2-0 vendor.thermal-hal-1-1 \
              vendor.thermal-hal-aidl thermal-hal-aidl vendor.thermal-hal-3-0 \
              vendor.thermal_service vendor.thermalserviced \
              mi_thermald vendor.oplus_thermald oplus_thermald vendor.oppo_thermal ; do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    # realme/OPPO 的 perf/调度守护进程（GT8 实机 `ps -A` 确认，v2.9）：
    #   perfservice / vendor-oplus-hardware-performance-V1-service / oplus_sched 会
    #   独立把大核(perf 簇) scaling_max_freq 压到最低档（960MHz），且读的是自有温度
    #   估算、不走 emul_temp 欺骗路径 —— 不显式停掉，日用限频会被实时抢回。
    #   逐个 ctl.stop，名字对不上/不存在的服务静默失败，无副作用。
    for _s in perfservice vendor.perfservice vendor.perfd perfd \
              perf2-hal-1-0 vendor.qti.hardware.perf2-hal-service \
              vendor-oplus-hardware-performance-V1-service \
              oplus_sched oplus_sched_rename \
              vendor.adpf vendor.thermal-mitigation thermal-mitigation ; do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    # v2.9（versionCode 53）：上面这些 perf/调度守护进程里，perfservice 与
    #   vendor-oplus-hardware-performance-V1-service、oplus_sched 是 init 用 `exec`
    #   直接拉起的（没有 init.svc 属性），`ctl.stop` 会报 "Unable to stop service"
    #   且完全不生效 —— 必须按进程名 kill。ps -A 显示完整进程名（不受 15 字符
    #   comm 截断限制，GT8 实机确认），awk 精确匹配末字段、取 PID 字段 kill。
    for _kn in perfservice vendor-oplus-hardware-performance-V1-service \
               oplus_sched oplus_sched_rename \
               vendor.qti.hardware.perf2-hal-service ; do
        # v2.12.0：改走 pid_of_name（pidof 优先 + ps 按表头定列）——
        # 原实现硬取 $2，在 busybox ps 上拿到的是 USER 名，kill 静默失效。
        _kpids=$(pid_of_name "$_kn")
        [ -n "$_kpids" ] && kill -9 $_kpids 2>/dev/null
    done
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
                    log_debug "还原冷却节点: $_p=$_v" ;;
        esac
    done < "$SYSFS_BAK"
    grep -v '/cooling_device.*/cur_state=' "$SYSFS_BAK" > "$SYSFS_BAK.tmp" 2>/dev/null
    mv -f "$SYSFS_BAK.tmp" "$SYSFS_BAK" 2>/dev/null
    : > "$PERSIST_DIR/.cdev_restored"
    log_info "cooling_device 已全部还原（UNLOCK_CDEV=0）"
}

# ── GPU devfreq 上限压制（unlock_perf 与 reapply_perf 共用）──────
# v2.9.2 优化：原先这段「遍历 GPU 节点 → 选档 → 写 max_freq」在 unlock_perf 与
# reapply_perf 里各写了一遍，两份实现要同步维护、极易改漏一边。抽成公共函数，
# 语义完全不变（unlock_perf 走 sysfs_set 带备份；reapply_perf 走裸写 + 值相同
# 跳过，因为原值早已备份过）。
#   $1 = 写值方式：bak=sysfs_set（带备份）/ raw=echo（值相同则跳过）
gpu_devfreq_cap() {
    [ "$UNLOCK_GPU" = "1" ] || return 0
    for _gd in /sys/class/kgsl/kgsl-3d0/devfreq /sys/class/devfreq/*kgsl* \
               /sys/class/devfreq/*gpu*; do
        [ -f "$_gd/available_frequencies" ] || continue
        # 纯 shell 选「≤ GPU_MAX_CLK 的最大档」，默认 INT_MAX 时等价于取最大值
        # （满血），设甜点值则自动封顶。零 fork。
        gpu_cap_target_into "$_gd/available_frequencies"
        [ -n "$_GCAP" ] || continue
        if [ "${1:-bak}" = "raw" ]; then
            _gcur=""
            read -r _gcur < "$_gd/max_freq" 2>/dev/null
            [ "$_gcur" = "$_GCAP" ] && continue
            echo "$_GCAP" > "$_gd/max_freq" 2>/dev/null
        else
            sysfs_set "$_gd/max_freq" "$_GCAP"
        fi
    done
    return 0
}

unlock_perf() {
    [ "$UNLOCK_FREQ" = "1" ] || return 0
    unlock_gpu
    for _cp in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -d "$_cp" ] || continue
        # v2.8.13 省电：read 内建替代两次 cat（8 核 = 16 次 fork → 0）
        _mx=""; read -r _mx < "$_cp/cpuinfo_max_freq" 2>/dev/null
        _mn=""; read -r _mn < "$_cp/cpuinfo_min_freq" 2>/dev/null
        [ -n "$_mx" ] && sysfs_set "$_cp/scaling_max_freq" "$_mx"
        [ -n "$_mn" ] && sysfs_set "$_cp/scaling_min_freq" "$_mn"
    done
    gpu_devfreq_cap bak
    # cooling_device 归零：默认关闭，且永远跳过显示/背光类节点
    [ "$UNLOCK_CDEV" = "1" ] || { restore_cdev_once; return 0; }
    for _c in /sys/class/thermal/cooling_device*; do
        [ -e "$_c/cur_state" ] || continue
        if [ "$DISPLAY_PROTECT" = "1" ] && is_display_cdev "$_c/cur_state"; then
            log_debug "跳过显示类冷却节点: $_c"
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
    # v2.8.13 修复（P1）：补回 scaling_min_freq 的周期压制。v2.8.12 靠 30s 一次
    # unlock_perf 写 min_freq，v2.8.13 拆维护后这一项被 reapply_perf 漏掉了 ——
    # 后果是 perf 服务抬高 min_freq 后不再被拉回（空闲时也更费电）。零 fork。
    for _f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
        [ -e "$_f" ] || continue
        _mn=""
        read -r _mn < "${_f%/*}/cpuinfo_min_freq" 2>/dev/null
        [ -n "$_mn" ] || continue
        _cur=""
        read -r _cur < "$_f" 2>/dev/null
        [ "$_cur" = "$_mn" ] && continue
        echo "$_mn" > "$_f" 2>/dev/null
    done
    # v2.8.13 修复（P1）：补回 GPU devfreq max_freq 的周期压制。这是关键 ——
    # 内核 devfreq governor 发热降频后，v2.8.12 靠 30s unlock_perf 拉回上限，
    # v2.8.13 拆维护后不拉了，GPU 降频不再恢复。零 fork；GPU_MAX_CLK 甜点值同样生效。
    # v2.9.2：与 unlock_perf 共用 gpu_devfreq_cap，消掉重复实现。
    gpu_devfreq_cap raw
}
