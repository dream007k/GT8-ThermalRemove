# GT8 ThermalRemove · common/spoof.sh
# emul_temp 温度欺骗核心 + OPPO 私有节点
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


# ── 判断内核是否支持温度仿真（emul_temp）───────────────────────
spoof_supported() {
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/emul_temp" ] && return 0
    done
    return 1
}

# ── 温感分类 → 目标欺骗温度 ───────────────────────────────────
# v2.8.13 省电：拆分出「算而不打印」的版本。
# 原 zone_target 靠 echo 返回值，调用处必须写 `$(zone_target …)` —— 命令替换
# 在 shell 里是**一个子 shell**，GT8 上 83 个温感 = 每轮 83 次 fork。
# 规则只在 _into 版里写一份，echo 版调它，避免两处规则走偏。
zone_target_into() {
    case "$1" in
        *batt*|*battery*|*usb*)        _ZTV=$BATT_T ;;
        *shell*|*skin*|*case*|*frame*) _ZTV=$SKIN_T ;;
        *cam*|*tof*|*flash*)           _ZTV=$CAM_T ;;
        *)                             _ZTV=$SOC_T ;;
    esac
}
zone_target() { zone_target_into "$1"; echo "$_ZTV"; }

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
# v2.8.13 省电（本函数是整个模块第二大开销，原实现一轮 ≈85 次 fork）：
#   · `cat "$_z/type"`        → `read -r` 内建，83 次 fork → 0
#   · `$(zone_target "$_ty")` → zone_target_into，83 次子 shell → 0
#   · `$(basename "$_z")`     → ${_z##*/} 参数展开，外部命令 → 0
#   · 周期性日志去重：重放时条数几乎不变，不再每 120s 写一行重复记录
# 行为完全不变：写入的值、跳过的温感、记账文件、返回值都与原来一致。
apply_spoof() {
    _n=0; _skip=0
    : > "$SPOOF_LIST.tmp" 2>/dev/null
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -f "$_z/temp" ] || continue
        if [ ! -e "$_z/emul_temp" ]; then
            _skip=$((_skip + 1))
            continue
        fi
        _ty=""
        read -r _ty < "$_z/type" 2>/dev/null
        [ -n "$_ty" ] || _ty=${_z##*/}
        is_blacklisted "$_ty" && continue
        case "$_ty" in
            *batt*|*battery*|*usb*)
                [ "$SPOOF_BATT" = "1" ] || continue
                ;;
        esac
        zone_target_into "$_ty"
        _tv=$_ZTV
        if echo "$_tv" > "$_z/emul_temp" 2>/dev/null; then
            _n=$((_n + 1))
            echo "$_z|$_tv" >> "$SPOOF_LIST.tmp" 2>/dev/null
        fi
    done
    mv -f "$SPOOF_LIST.tmp" "$SPOOF_LIST" 2>/dev/null
    oppo_nodes_on

    # 日志去重：只在「本次结果签名变了」时记录；此外每 LOG_HEARTBEAT 次
    # 补一条心跳（保留「模块还活着、还在重放」这一可观测证据）。
    # 原来每 30s 一行，一天 2880 行内容几乎完全相同 —— 纯日志 I/O 与 date fork。
    _as_sig="$_n/$_skip"
    _as_log=0
    if [ "$_as_sig" != "${_SPOOF_LOG_SIG:-}" ]; then
        _as_log=1
    else
        _SPOOF_LOG_N=$(( ${_SPOOF_LOG_N:-0} + 1 ))
        if [ "${LOG_HEARTBEAT:-12}" -gt 0 ] 2>/dev/null && \
           [ "${_SPOOF_LOG_N:-0}" -ge "${LOG_HEARTBEAT:-12}" ] 2>/dev/null; then
            _as_log=1; _SPOOF_LOG_N=0
        fi
    fi
    if [ "$_as_log" = "1" ]; then
        log_info "欺骗已应用：$_n 个温感${_skip:+，$_skip 个不支持 emul_temp}"
        _SPOOF_LOG_SIG=$_as_sig
    fi
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
    log_info "欺骗已撤销：$_n 个温感"
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
