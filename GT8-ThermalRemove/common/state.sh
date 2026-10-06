# GT8 ThermalRemove · common/state.sh
# 状态决策：充电检测 / 前台应用 / decide_state / maintain_state
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


# ── 场景检测 ──────────────────────────────────────────────────
get_charging_into() {
    # v2.8.12 性能：原实现每轮 cat 遍历所有 power_supply 节点（GT8 上 5~8 个）= 5~8 次 fork。
    # read 是 shell 内建命令，重定向读第一行即可，零 fork。
    # v2.8.13：再去掉 `echo` —— 调用处 `$(get_charging)` 的命令替换本身就是要
    # fork 一个子 shell 的，一天 17280 次。改为写全局变量 _CHG，echo 版留作兼容。
    _CHG=0
    for _p in /sys/class/power_supply/*/status; do
        [ -f "$_p" ] || continue
        _st=""
        read -r _st < "$_p" 2>/dev/null
        case "$_st" in
            Charging|Full) _CHG=1; return 0 ;;
        esac
    done
    return 0
}
get_charging() { get_charging_into; echo "$_CHG"; }

get_focus_app() {
    # v2.8.12 性能：原来只匹配 'topResumedActivity='，而不同 Android 版本的字段名不同
    # （还有 mResumedActivity / ResumedActivity / mFocusedApp 几种写法）。一旦本机不是
    # topResumedActivity，第一次必然落空 → 每轮跑**两次**重型 dumpsys。
    # 现在一次 dumpsys 匹配全部常见写名；真要全落空，行为与原来完全一致。
    _line=$(dumpsys activity activities 2>/dev/null | \
            grep -m1 -E 'topResumedActivity=|mResumedActivity=|ResumedActivity|mFocusedApp=')
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

# v2.8.13 省电：两个列表文件几乎从不变化，没必要每 5 秒各重扫一遍（纯 shell
# 但仍是逐行字符串处理，一天 17280×2 次）。缓存机制与 load_conf 一致：
# mtime 变才重扫 + CONF_FORCE_TICKS 强制兜底，全部零 fork。
_LIST_VALID=0
_LIST_TICK=0
_HE_PROT=0
_HE_GAME=0
_he_refresh() {
    _he_need=0
    if [ "$_LIST_VALID" = "1" ]; then
        _LIST_TICK=$((_LIST_TICK + 1))
        [ "$PROTECT_LIST" -nt "$LIST_STAMP" ] && _he_need=1
        [ "$GAME_LIST"    -nt "$LIST_STAMP" ] && _he_need=1
        if [ "${_LIST_TICK:-0}" -ge "${CONF_FORCE_TICKS:-12}" ] 2>/dev/null; then
            _he_need=1; _LIST_TICK=0
        fi
    else
        _he_need=1; _LIST_TICK=0
    fi
    [ "$_he_need" = "1" ] || return 0
    if _has_effective "$PROTECT_LIST"; then _HE_PROT=1; else _HE_PROT=0; fi
    if _has_effective "$GAME_LIST";   then _HE_GAME=1; else _HE_GAME=0; fi
    [ "$CONF_PERSISTENT" = "1" ] && : > "$LIST_STAMP" 2>/dev/null
    _LIST_VALID=1
    return 0
}

decide_state_into() {
    [ "${1:-1}" = "1" ] && load_conf
    if [ "$MODE" = "off" ];    then DECIDE_RESULT=0; return 0; fi
    # v2.12.0：温度保险丝冷却期内一律返回「保护」——
    # 否则 5 秒检测层会立刻把刚被保险丝撤掉的欺骗重新打开，来回抖动。
    if [ "${_FUSE_TICKS:-0}" -gt 0 ] 2>/dev/null; then DECIDE_RESULT=0; return 0; fi
    if [ "$MODE" = "always" ]; then DECIDE_RESULT=1; return 0; fi

    get_charging_into
    if [ "$_CHG" = "1" ]; then DECIDE_RESULT=0; return 0; fi

    # v2.8.12 性能：只有「真的可能命中」时才去查前台应用。
    # 原实现无条件调用 get_focus_app —— 而它跑的是 dumpsys activity activities，
    # 一个输出数百 KB 的重型 Binder 调用，每 5 秒一次（一天 1.7 万次）。
    # 默认配置下 protect_list.conf 全是注释、GAME_PROTECT=0，查出来的包名根本没人用。
    # 加这道闸后，「没配保护/游戏列表」的用户彻底不再触发 dumpsys。
    _he_refresh
    if [ "$_HE_PROT" = "1" ] || { [ "$GAME_PROTECT" = "1" ] && [ "$_HE_GAME" = "1" ]; }; then
        _app=$(get_focus_app)
        if [ -n "$_app" ]; then
            if is_in_list "$PROTECT_LIST" "$_app"; then DECIDE_RESULT=0; return 0; fi
            if [ "$GAME_PROTECT" = "1" ] && is_in_list "$GAME_LIST" "$_app"; then
                DECIDE_RESULT=0; return 0
            fi
        fi
    fi
    DECIDE_RESULT=1
    return 0
}

decide_state() {
    # 保留原「打印结果」的接口；主循环请用 decide_state_into（零 fork）
    decide_state_into "${1:-1}"
    echo "$DECIDE_RESULT"
}

# ── 应用 / 撤销主逻辑 ─────────────────────────────────────────
apply_state() {
    _want="$1"
    # v2.8.13 省电：read 内建替代 `$(cat)`（每次调用省一个子 shell）
    _cur=""
    read -r _cur < "$STATE_FILE" 2>/dev/null

    if [ "$_want" = "1" ]; then
        [ "$STOP_SERVICES" = "1" ] && stop_thermal_services
        orms_off
        mount_config_overlays
        unlock_perf
        oppo_horae_testmode
        touch_boost
        touch_thread_boost
        apply_spoof > /dev/null
        [ "$_cur" = "on" ] || log_info "→ 温控已移除 (mode=$MODE)"
        echo "on" > "$STATE_FILE"
    else
        restore_spoof > /dev/null
        unmount_config_overlays
        restore_sysfs
        # v2.8.8：温控保护期间也把输入线程优先级还原（提权与去温控同属「性能模式」）
        touch_thread_restore
        rm -f "$PERSIST_DIR/.cdev_restored"
        orms_on
        [ "$_cur" = "off" ] || log_info "→ 温控已恢复 (mode=$MODE)"
        echo "off" > "$STATE_FILE"
    fi
}

# ── v2.8.13 省电：状态没变时的「轻维护」 ─────────────────────────
# 原实现每 30s 调一次**完整** apply_state 1，把挂载校验、全量频解锁、ORMS、
# 触控提权、83 个温感重放全套跑一遍。状态没变时，其中大部分是纯空转 ——
# 挂载还在、备份早记过、优先级也没丢。
# 这里只保留「确实可能被系统/其它进程写回、需要周期性压制」的部分：
#   · apply_spoof     内核或其它模块可能清掉 emul_temp → 必须重放
#   · reapply_perf    内核 thermal core 会周期写回 scaling_max_freq → 需要压制
#   · touch_boost / touch_thread_boost   触控服务重启后 pid 变了要补提权
#   · stop_thermal_services / orms_off   init 可能把服务重新拉起（两者默认关）
#   · mount_config_overlays             带「整体校验」快速路径，挂载丢了才补挂
# 不做的是：unlock_perf 的全量备份式写入、状态文件重写、切换日志 ——
# 状态既然没变，就没有任何新信息可写。
# 所有被跳过的步骤在**状态切换时**仍会由 apply_state 完整执行，行为不缺失。
maintain_state() {
    [ "$UNLOCK_FREQ" = "1" ] && reapply_perf
    # v2.8.13 修复（P2）：apply_spoof 返回写入成功的温感数；全部失败（0）时
    # 记账会被 mv 成空、state 却仍是 on，主循环会以为还在欺骗。记日志并置
    # _SPOOF_FAILED，让 service.sh 缩短下次维护间隔（几秒后重试），
    # 而不是干等 120s。原 v2.8.12 是 30s 重试一次，这里至少保住自愈能力。
    _sp_n=$(apply_spoof 2>/dev/null)
    if [ "$_sp_n" = "0" ]; then
        _SPOOF_FAILED=1
        log_warn "! 重放失败：0 个温感写入成功，提前重试"
    else
        _SPOOF_FAILED=0
    fi
    oppo_horae_testmode
    touch_boost
    touch_thread_boost
    [ "$STOP_SERVICES" = "1" ] && stop_thermal_services
    [ "$DISABLE_ORMS"  = "1" ] && orms_off
    mount_config_overlays
    # v2.12.0：温度保险丝挂在维护周期里（低频、只在欺骗生效时才有意义）
    [ "$FUSE_ENABLE" = "1" ] && fuse_tick
    # v2.16.0 F5：温频历史快照（真实温度 + CPU/GPU 频率），供 WebUI 曲线
    history_snapshot
    return 0
}

# ── v2.16.0 F5：温频历史快照 ─────────────────────────────────
# 每维护周期采一轮：SoC 真实温度（_fuse_read_one，原值恢复）+ cpu0/cpu6/GPU 当前频率，
# 追加到 HISTORY_LIST（滚动 120 条 ≈ 4 小时）。除采 SoC 真值的一次 emul_temp 写外，
# 频率全是纯读；供 WebUI「温频曲线」量化「去温控有没有效果」。
history_snapshot() {
    # 找 SoC 温感（复用保险丝匹配规则，排除黑名单）
    _hs_z=""
    for _hz in /sys/class/thermal/thermal_zone*; do
        [ -e "$_hz/emul_temp" ] && [ -e "$_hz/temp" ] || continue
        _hty=""; read -r _hty < "$_hz/type" 2>/dev/null
        [ -n "$_hty" ] || continue
        is_blacklisted "$_hty" && continue
        case "$_hty" in *soc*|*cpu-0-*|*ap*) _hs_z="$_hz"; break ;; esac
    done
    _hs_soc=""
    [ -n "$_hs_z" ] && _fuse_read_one "$_hs_z" && _hs_soc="$_FR_VAL"
    # 频率（纯读；cpu6 / GPU 跨机型兜底）
    _hs_c0=""; read -r _hs_c0 < /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null
    _hs_c6=""; read -r _hs_c6 < /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null
    _hs_gpu=""
    read -r _hs_gpu < /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq 2>/dev/null
    [ -z "$_hs_gpu" ] && read -r _hs_gpu < /sys/class/devfreq/3d00000.qcom,kgsl-3d0/cur_freq 2>/dev/null
    # 追加 + 滚动（tail/mv 每周期各一次 fork，文件 <120 行时开销可忽略）
    echo "$(date +%s) ${_hs_soc:-0} ${_hs_c0:-0} ${_hs_c6:-0} ${_hs_gpu:-0}" >> "$HISTORY_LIST" 2>/dev/null
    tail -n 120 "$HISTORY_LIST" > "$HISTORY_LIST.tmp" 2>/dev/null && \
        mv -f "$HISTORY_LIST.tmp" "$HISTORY_LIST" 2>/dev/null
    return 0
}

# ── v2.15.0 F4：按前台应用自动切档 ────────────────────────────
# 命中 game_list 的前台应用 → 自动应用 game 档；退出游戏 → 恢复切档前最接近的档。
# 依赖 presets.sh（preset_apply / preset_match_into / preset_pairs）。
# 状态全部进程内（service.sh 长驻）：_AUTO_GAME_ACTIVE（自动 game 态）、
# _AUTO_GAME_LEAVE（连续非游戏次数，防桌面停留抖动）、_AUTO_NEAREST（切档前最接近的非 game 档）。
# 检测节奏由 service.sh 主循环控制（默认 30s），本函数只做「本次检测」的判定与切档。

# 找当前配置最接近的非 game 档（stock/daily/cool/debug），结果写 _AUTO_NEAREST。
# 匹配率 < 50% 视为「完全自定义」，留空（退出游戏时不覆盖用户的自定义配置）。
_auto_find_nearest() {
    _AUTO_NEAREST=""
    _an_best=49
    for _an_id in stock daily cool debug; do
        preset_match_into "$_an_id"
        [ "${_PMT_T:-0}" -gt 0 ] 2>/dev/null || continue
        _an_ratio=$(( _PMT_M * 100 / _PMT_T ))
        if [ "$_an_ratio" -gt "$_an_best" ] 2>/dev/null; then
            _an_best=$_an_ratio
            _AUTO_NEAREST="$_an_id"
        fi
    done
}

auto_game_preset_tick() {
    [ "$AUTO_GAME_PRESET" = "1" ] || { _AUTO_GAME_ACTIVE=0; _AUTO_GAME_LEAVE=0; return 0; }
    _AUTO_GAME_ACTIVE="${_AUTO_GAME_ACTIVE:-0}"
    _AUTO_GAME_LEAVE="${_AUTO_GAME_LEAVE:-0}"
    _he_refresh
    [ "$_HE_GAME" = "1" ] || { _AUTO_GAME_ACTIVE=0; _AUTO_GAME_LEAVE=0; return 0; }
    _ag_app=$(get_focus_app)
    # v2.15.3：debug 心跳 —— 每 30s 打印一次前台包名与命中判定，用于确认 F4 是否在跑、
    # get_focus_app 解析是否正确。info 阈值下零成本（分级判断在 date 之前，见 log.sh）。
    if [ -n "$_ag_app" ] && is_in_list "$GAME_LIST" "$_ag_app"; then
        log_debug "F4 心跳：前台包名=[$_ag_app] 命中游戏=是"
        # 前台是游戏
        _AUTO_GAME_LEAVE=0
        if [ "$_AUTO_GAME_ACTIVE" != "1" ]; then
            _auto_find_nearest
            if preset_apply game; then
                _AUTO_GAME_ACTIVE=1
                log_info "✓ 自动切档：检测到游戏 $_ag_app → 应用 game 档（之前最接近 ${_AUTO_NEAREST:-自定义}）"
            fi
        fi
    elif [ "$_AUTO_GAME_ACTIVE" = "1" ]; then
        # 前台非游戏：连续 3 次（约 90s）才恢复，避免切桌面回消息时来回抖档
        _AUTO_GAME_LEAVE=$((_AUTO_GAME_LEAVE + 1))
        log_debug "F4 心跳：前台包名=[${_ag_app:-空}] 命中游戏=否（累计离开 ${_AUTO_GAME_LEAVE}/3）"
        if [ "$_AUTO_GAME_LEAVE" -ge 3 ] 2>/dev/null; then
            if [ -n "$_AUTO_NEAREST" ]; then
                preset_apply "$_AUTO_NEAREST" && log_info "✓ 自动切档：游戏退出 → 恢复 $_AUTO_NEAREST 档"
            else
                log_info "✓ 自动切档：游戏退出，保持当前配置（之前为自定义，不覆盖）"
            fi
            _AUTO_GAME_ACTIVE=0; _AUTO_GAME_LEAVE=0
        fi
    else
        log_debug "F4 心跳：前台包名=[${_ag_app:-空}] 命中游戏=否"
    fi
    return 0
}
