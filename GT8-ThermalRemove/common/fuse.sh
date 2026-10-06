# GT8 ThermalRemove · common/fuse.sh
# 温度保险丝（v2.12.0）+ 开机自救 / 安全模式
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


# ══════════════════════════════════════════════════════════════
#  v2.12.0 · 温度保险丝（FUSE）
#
#  为什么需要：本模块此前唯一的安全网是 SoC 硬件结温保护（Tj），而 always 模式连
#  电池过温保护也一并移除 —— 这是文档反复警告、但**软件层面完全没有兜底**的组合。
#  保险丝补上这一层：定期读关键温感的**真实温度**（不是我们写进去的伪装值），
#  越界就立刻撤销欺骗、回原厂保护，并在冷却期内拒绝重新欺骗。
#
#  设计约束：
#   · 低频 —— 每 MAINT_SECONDS（120s）一轮，只采电池 / SoC / 外壳各一路；
#   · 短暴露 —— 写 emul_temp=0 → 读 temp → 立刻写回伪装值（与 api.sh 的真实温度
#     探测同一手法），并复用 REAL_ZERO_MARK 自愈标记，中途被杀下一轮能恢复；
#   · 判定零 fork —— 冷却用进程内 tick 计数，不读时间、不写状态文件；
#   · 默认保守 —— 电池 45℃ 起跳；三路阈值全 0 即整体关闭。
# ══════════════════════════════════════════════════════════════

_realzero_lock() {
    # 持锁期间锁目录内放 pid 文件：①别人删不掉（目录非空）→ 不会被抢锁；
    # ②本进程被杀后残留的锁可由「pid 是否还活着」精确识别并清理（不用 find，
    #   find -maxdepth/-mmin 在部分环境的 find 上不受支持，会退化成全盘遍历）。
    if mkdir "$REAL_ZERO_LOCK" 2>/dev/null; then
        printf '%s' "$$" > "$REAL_ZERO_LOCK/pid" 2>/dev/null
        return 0
    fi
    _rzp=""; read -r _rzp < "$REAL_ZERO_LOCK/pid" 2>/dev/null
    case "$_rzp" in
        ''|*[!0-9]*) : ;;                 # 损坏/缺失的 pid 文件 → 当作陈旧处理
        *) kill -0 "$_rzp" 2>/dev/null && return 1 ;;   # 持锁者还活着 → 放弃本轮
    esac
    rm -rf "$REAL_ZERO_LOCK" 2>/dev/null
    if mkdir "$REAL_ZERO_LOCK" 2>/dev/null; then
        printf '%s' "$$" > "$REAL_ZERO_LOCK/pid" 2>/dev/null
        return 0
    fi
    return 1
}
_realzero_unlock() {
    # 只释放**自己**持有的锁：pid 不匹配就什么都不做。现有调用路径都只在 lock
    # 成功后配对 unlock，但一旦将来出现「lock 失败也走 unlock」的分支，无保护的
    # unlock 会把别人的活锁删掉 → 互斥形同虚设。校验一行成本，换掉整类隐患。
    _rzu=""; read -r _rzu < "$REAL_ZERO_LOCK/pid" 2>/dev/null
    [ "$_rzu" = "$$" ] || return 0
    rm -rf "$REAL_ZERO_LOCK" 2>/dev/null
    return 0
}

_fuse_msleep() {
    _fm="$1"
    case "$_fm" in ''|*[!0-9]*) _fm=80 ;; esac
    [ "$_fm" -lt 1 ] && return 0
    if command -v usleep >/dev/null 2>&1; then
        usleep "$((_fm * 1000))" 2>/dev/null && return 0
    fi
    sleep "0.$(printf '%03d' "$_fm")" 2>/dev/null || sleep 1
    return 0
}

# 单路探测：$1=温感目录 $2=阈值(0=关闭该路) $3=线路名
# 返回 1 = 读到可信真值且超阈值（_FUSE_ROUTE / _FUSE_VAL 已写）；0 = 未触发
_fuse_probe_one() {
    _fp_d="$1"; _fp_th="$2"; _fp_rt="$3"
    case "$_fp_th" in ''|0) return 0 ;; esac
    [ -n "$_fp_d" ] && [ -e "$_fp_d/emul_temp" ] && [ -e "$_fp_d/temp" ] || return 0
    _fp_ty=""; read -r _fp_ty < "$_fp_d/type" 2>/dev/null
    [ -n "$_fp_ty" ] || _fp_ty=${_fp_d##*/}
    zone_target_into "$_fp_ty"; _fp_spoof="$_ZTV"
    # v2.17.2：拿不到互斥锁就跳过本轮采样（详见 functions.sh REAL_ZERO_LOCK 注释）
    _realzero_lock || return 0
    # 短暂关闭仿真读真值；写不进去（被第三方加锁等）就跳过本轮
    if ! echo 0 > "$_fp_d/emul_temp" 2>/dev/null; then
        _realzero_unlock; return 0
    fi
    echo "$_fp_d|$_fp_spoof" >> "$REAL_ZERO_MARK" 2>/dev/null
    _fuse_msleep "${FUSE_DELAY_MS:-80}"
    _fp_real=""; read -r _fp_real < "$_fp_d/temp" 2>/dev/null
    # 立刻恢复伪装值（缩短暴露窗口）并清掉恢复标记 —— 顺序不能反
    echo "$_fp_spoof" > "$_fp_d/emul_temp" 2>/dev/null
    : > "$REAL_ZERO_MARK" 2>/dev/null
    _realzero_unlock
    case "$_fp_real" in ''|*[!0-9-]*) return 0 ;; esac
    [ "$_fp_real" = "$_fp_spoof" ] && return 0     # 读到的仍是伪装值 → 内核未刷新，不可信
    [ "$_fp_real" -gt "$_fp_th" ] 2>/dev/null || return 0
    _FUSE_ROUTE="$_fp_rt"; _FUSE_VAL="$_fp_real"
    return 1
}

# 采一轮：任一路越界返回 1（触发），否则返回 0（未触发）。
# 遍历只挑每路第一个命中项，成本恒定（不随温感数量增长）。
fuse_sample_check() {
    [ "$FUSE_ENABLE" = "1" ] || return 0
    _fsz_batt=""; _fsz_soc=""; _fsz_skin=""
    for _fz in /sys/class/thermal/thermal_zone*; do
        [ -e "$_fz/emul_temp" ] && [ -e "$_fz/temp" ] || continue
        _fty=""; read -r _fty < "$_fz/type" 2>/dev/null
        [ -n "$_fty" ] || continue
        is_blacklisted "$_fty" && continue
        case "$_fty" in
            # v2.14.3：电池路优先 battery/batt（真实电池温度）；usb 只在无 battery 时兜底 ——
            # 此前把 usb 与 battery 并列「取首个」，而遍历顺序 usb 先于 battery，
            # 真机上选到 usb（读 3.1°C 异常低温），电池过温保护因此永远不触发。
            *batt*|*battery*)                 _fsz_batt=$_fz ;;
            *usb*)                            [ -z "$_fsz_batt" ] && _fsz_batt=$_fz ;;
            *soc*|*cpu*|*ap*|*gpu*|*tsens*)  [ -z "$_fsz_soc" ]  && _fsz_soc=$_fz  ;;
            *skin*|*shell*|*case*|*frame*)   [ -z "$_fsz_skin" ] && _fsz_skin=$_fz ;;
        esac
    done
    _fuse_probe_one "$_fsz_batt" "${FUSE_TEMP_BATT:-45000}" 电池 || return 1
    _fuse_probe_one "$_fsz_soc"  "${FUSE_TEMP_SOC:-80000}" SoC  || return 1
    _fuse_probe_one "$_fsz_skin" "${FUSE_TEMP_SKIN:-46000}" 外壳 || return 1
    return 0
}

# 维护周期调用：冷却递减 → 本轮采样 → 触发动作
fuse_tick() {
    [ "$FUSE_ENABLE" = "1" ] || return 0
    if [ "${_FUSE_TICKS:-0}" -gt 0 ] 2>/dev/null; then
        _FUSE_TICKS=$((_FUSE_TICKS - 1))
        if [ "$_FUSE_TICKS" -le 0 ]; then
            _FUSE_TICKS=0
            log_info "✓ 温度保险丝冷却结束：按 MODE=$MODE 恢复原策略"
        else
            log_debug "温度保险丝冷却中（剩 $_FUSE_TICKS 个维护周期）"
        fi
        return 0
    fi
    # fuse_sample_check 的返回语义：0 = 未触发（继续走），1 = 触发（往下走动作）
    if fuse_sample_check; then
        return 0
    fi
    # ── 触发：撤销欺骗 + 进入冷却 ──
    # 冷却时长按维护周期折算成 tick 数；主循环 decide_state 会因它返回 0，
    # 从而在冷却期内**不会**被 5s 检测层重新打开（否则会来回抖动）。
    _FUSE_TRIPS=$(( ${_FUSE_TRIPS:-0} + 1 ))
    _ct=$(( ${FUSE_COOLDOWN:-120} / ${MAINT_SECONDS:-120} ))
    [ "$_ct" -lt 1 ] && _ct=1
    _FUSE_TICKS=$_ct
    log_warn "⚠ 温度保险丝触发[$_FUSE_ROUTE]：真实温度 $_FUSE_VAL 毫摄氏度超阈值 → 撤销欺骗，${FUSE_COOLDOWN}s 内不恢复"
    echo "[$(date '+%m-%d %H:%M:%S')] $_FUSE_ROUTE=$_FUSE_VAL" >> "$FUSE_LOG" 2>/dev/null
    apply_state 0
    return 0
}

# 诊断用：触发次数（读记录文件行数，零副作用）
fuse_trips() {
    _ft_n=0
    [ -s "$FUSE_LOG" ] && _ft_n=$(wc -l < "$FUSE_LOG" 2>/dev/null | tr -d ' ')
    case "$_ft_n" in ''|*[!0-9]*) _ft_n=0 ;; esac
    printf '%s' "$_ft_n"
}

# 诊断用：读单路真实温度（只读展示，不触发）。与 _fuse_probe_one 的差别只有
#   「不比较阈值、不触发动作」。写回伪装值用 zone_target_into（而非回读 emul_temp
#   原值）—— 本内核 emul_temp 回读恒为空，回读原值会误判为 0、写回 0 从而撤销欺骗。
# $1=温感目录；读到可信真值返回 0 并写 _FR_VAL，否则返回 1。
_fuse_read_one() {
    _fr_d="$1"; _FR_VAL=""
    [ -n "$_fr_d" ] && [ -e "$_fr_d/emul_temp" ] && [ -e "$_fr_d/temp" ] || return 1
    _fr_ty=""; read -r _fr_ty < "$_fr_d/type" 2>/dev/null
    [ -n "$_fr_ty" ] || _fr_ty="${_fr_d##*/}"
    zone_target_into "$_fr_ty"; _fr_spoof="$_ZTV"
    # v2.17.2：拿不到互斥锁就如实返回失败（不冒充；调用方据此显示「读不到」）
    _realzero_lock || return 1
    # 短暂关仿真读真值；写不进去就如实返回失败（不冒充）
    if ! echo 0 > "$_fr_d/emul_temp" 2>/dev/null; then
        _realzero_unlock; return 1
    fi
    echo "$_fr_d|$_fr_spoof" >> "$REAL_ZERO_MARK" 2>/dev/null
    _fuse_msleep "${FUSE_DELAY_MS:-80}"
    _fr_r=""; read -r _fr_r < "$_fr_d/temp" 2>/dev/null
    # 立刻写回伪装值（zone_target_into，与 _fuse_probe_one 一致）—— 顺序不能反
    echo "$_fr_spoof" > "$_fr_d/emul_temp" 2>/dev/null
    : > "$REAL_ZERO_MARK" 2>/dev/null
    _realzero_unlock
    case "$_fr_r" in ''|*[!0-9-]*) return 1 ;; esac
    [ "$_fr_r" = "$_fr_spoof" ] && return 1   # 读到伪装值 = 内核未刷新，不可信
    _FR_VAL="$_fr_r"
    return 0
}

# 诊断用：展示一路真实温度（配合 _fuse_read_one）
_fuse_show_line() {
    _fl_d="$1"; _fl_name="$2"; _fl_th="$3"
    _fl_ty=""; [ -n "$_fl_d" ] && read -r _fl_ty < "$_fl_d/type" 2>/dev/null
    [ -n "$_fl_ty" ] || _fl_ty="${_fl_d##*/}"
    if _fuse_read_one "$_fl_d"; then
        _fl_c=$(( _FR_VAL / 100 ))
        _fl_ci=$(( _fl_c / 10 )); _fl_cf=$(( _fl_c % 10 ))
        _fl_flag=""
        [ "$_fl_th" != "0" ] && [ "$_FR_VAL" -gt "$_fl_th" ] 2>/dev/null && _fl_flag="  ⚠ 已超阈值"
        echo "  ${_fl_name}  (${_fl_ty:-未命中}) = ${_FR_VAL} 毫摄氏度 (${_fl_ci}.${_fl_cf}°C)${_fl_flag}"
    else
        echo "  ${_fl_name}  (${_fl_ty:-未命中}) = --（读不到可信真值：该路不支持/未欺骗/内核不刷新）"
    fi
}

# 诊断用：保险丝状态 + 三路真实温度 + 触发记录 + 安全模式（纯只读，不触发）。
# 供 `sh action.sh fuse` 与诊断包 07-fuse.txt 复用。
# 约定：调用前需 load_conf（读 FUSE_* / BOOT_FAIL_LIMIT 变量），与 doctor_report 一致；
#       FUSE_DELAY_MS 可经环境变量覆盖（测试设 0 跳过采样等待）。
fuse_report() {
    echo "=== 温度保险丝（FUSE）==="
    echo "开关           : $([ "$FUSE_ENABLE" = "1" ] && echo 开启 || echo 关闭)"
    echo "阈值（毫摄氏度）: 电池/${FUSE_TEMP_BATT:-45000}  SoC/${FUSE_TEMP_SOC:-80000}  外壳/${FUSE_TEMP_SKIN:-46000}   (0=关闭该路)"
    echo "冷却时长       : ${FUSE_COOLDOWN:-120}s（触发后此期间不再重新移除温控）"
    echo "采样等待       : ${FUSE_DELAY_MS:-80}ms（写 emul_temp=0 后等多久再读真值）"
    echo "累计触发次数   : $(fuse_trips)"
    echo
    echo "=== 三路真实温度（短暂写 emul_temp=0 采真值后原样写回，无副作用）==="
    _fr_b=""; _fr_s=""; _fr_k=""
    for _fr_z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_fr_z/emul_temp" ] && [ -e "$_fr_z/temp" ] || continue
        _fr_ty=""; read -r _fr_ty < "$_fr_z/type" 2>/dev/null
        [ -n "$_fr_ty" ] || continue
        is_blacklisted "$_fr_ty" && continue
        case "$_fr_ty" in
            *batt*|*battery*)                 _fr_b=$_fr_z ;;
            *usb*)                            [ -z "$_fr_b" ] && _fr_b=$_fr_z ;;
            *soc*|*cpu*|*ap*|*gpu*|*tsens*)  [ -z "$_fr_s" ] && _fr_s=$_fr_z ;;
            *skin*|*shell*|*case*|*frame*)   [ -z "$_fr_k" ] && _fr_k=$_fr_z ;;
        esac
    done
    _fuse_show_line "$_fr_b" "电池" "${FUSE_TEMP_BATT:-45000}"
    _fuse_show_line "$_fr_s" "SoC " "${FUSE_TEMP_SOC:-80000}"
    _fuse_show_line "$_fr_k" "外壳" "${FUSE_TEMP_SKIN:-46000}"
    # v2.14.1：探测结束按记账全量重放，确保欺骗恢复 —— 本内核写 emul_temp=0 后
    # 写回伪装值可能失败（Permission denied），若不兜底会留下「欺骗被撤销」的窗口，
    # 要等 service.sh 下一个维护周期（≤120s）才恢复。
    if [ -s "$SPOOF_LIST" ]; then
        _fr_rep=0
        while IFS='|' read -r _fr_d2 _fr_v2; do
            [ -n "$_fr_d2" ] && [ -e "$_fr_d2/emul_temp" ] || continue
            echo "$_fr_v2" > "$_fr_d2/emul_temp" 2>/dev/null && _fr_rep=$((_fr_rep + 1))
        done < "$SPOOF_LIST"
        : > "$REAL_ZERO_MARK" 2>/dev/null
        echo "  （探测后已按记账重放 $_fr_rep 个温感，恢复欺骗）"
    fi
    echo
    echo "=== 保险丝触发记录（fuse.log）==="
    if [ -s "$FUSE_LOG" ]; then
        tail -n 10 "$FUSE_LOG" 2>/dev/null
    else
        echo "  （无 —— 说明保险丝从未触发过，正常情况就是没有）"
    fi
    echo
    echo "=== 安全模式 / 开机自救 ==="
    if safe_mode_active; then
        echo "  安全模式 : 已激活（当前为保护态，MODE 会按 off 处理）"
    else
        echo "  安全模式 : 未激活"
    fi
    _bt=$(cat "$BOOT_TOKEN" 2>/dev/null); case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
    echo "  boot token : ${_bt} 次未完成开机（阈值 BOOT_FAIL_LIMIT=${BOOT_FAIL_LIMIT:-3}）"
}

# ══════════════════════════════════════════════════════════════
#  v2.12.0 · 开机自救（boot token）与安全模式
#
#  连续 BOOT_FAIL_LIMIT 次开机没走到 boot-completed（崩溃 / 卡开机 / 被别的模块
#  搞挂），说明上一轮的配置很可能有问题 —— 此时自动把 MODE 置 off 并把温控还给
#  原厂，保证设备一定能进系统。这是 KernelSU 模块的通用自救惯例。
# ══════════════════════════════════════════════════════════════
boot_token_bump() {
    _bt=0
    [ -f "$BOOT_TOKEN" ] && { read -r _bt < "$BOOT_TOKEN" 2>/dev/null; }
    case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
    _bt=$((_bt + 1))
    echo "$_bt" > "$BOOT_TOKEN" 2>/dev/null
    printf '%s' "$_bt"
}

boot_token_clear() { echo 0 > "$BOOT_TOKEN" 2>/dev/null; return 0; }

# 安全模式标记以「文件非空」为准：进入时写入时间戳，退出时清零内容。
# 刻意不用 rm —— `: >` 是内建重定向（零 fork），也不必依赖外部命令是否可用。
safe_mode_active() { [ -s "$SAFE_MODE_MARK" ]; }

# 进入安全模式：撤销一切改写 + MODE=off + 留标记（供 WebUI/status 展示）。
# 手动（action.sh panic）与自动（boot token 超限）共用这一份实现。
panic_to_safe() {
    apply_state 0 2>/dev/null
    if [ -f "$MODE_CONF" ]; then
        sed -i 's|^MODE=.*|MODE=off|' "$MODE_CONF" 2>/dev/null
    else
        printf 'MODE=off\n' > "$MODE_CONF" 2>/dev/null
    fi
    MODE=off
    date '+%Y-%m-%d %H:%M:%S' > "$SAFE_MODE_MARK" 2>/dev/null
    return 0
}

# 用户手动改回 on/dynamic 时清掉安全模式标记（action.sh set_mode 调用）
# 只清内容不删文件：`: >` 零 fork，且与 safe_mode_active 的「非空」判据严格配套。
safe_mode_exit() {
    : > "$SAFE_MODE_MARK" 2>/dev/null
    return 0
}
