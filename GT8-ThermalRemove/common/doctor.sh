# GT8 ThermalRemove · common/doctor.sh
# 一键体检 doctor + 诊断工具（dump_temp/dump_cdev）+ 清理
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


# ── v2.12.0：清理 CGI 遗留的临时文件 ──────────────────────────
# api.sh 每请求一个 PID（$$），异常退出（httpd 被杀 / 请求超时）会留下 gt8_*.PID
# 一族文件。只清理本模块前缀且 2 小时以上未修改的，避免误删其他程序的文件。
cleanup_stale_tmp() {
    _ct_dir="${TMPDIR:-/data/local/tmp}"
    [ -d "$_ct_dir" ] || return 0
    find "$_ct_dir" -maxdepth 1 -name 'gt8_*' -mmin +120 -delete 2>/dev/null
    return 0
}

# ── v2.13.0 · 一键体检（doctor）───────────────────────────────
# 纯只读报告，供 action.sh doctor / api.sh --doctor / WebUI「体检」复用。
# 全程不 apply / 不 restore / 不写盘（只读 source 已有函数），零副作用。
# 8 节：设备版本 / 内核能力 / 温感命中 / 欺骗状态 / 冲突 / 配置 / 风险 / 依赖权限。
doctor_report() {
    load_conf 2>/dev/null
    echo "== 1/8 设备与版本 =="
    echo "  机型     : $(getprop ro.product.model 2>/dev/null || echo unknown)"
    echo "  Android  : $(getprop ro.build.version.release 2>/dev/null || echo unknown) (SDK $(getprop ro.build.version.sdk 2>/dev/null || echo ?))"
    echo "  内核     : $(uname -r 2>/dev/null || echo unknown)"
    echo "  模块版本 : $(conf_get "$MODDIR/module.prop" version unknown)"
    _dr_ksu=""
    for _dr_kp in ro.sukisu.version ro.sukisu.version.name ro.kernelsu.version \
                   persist.ksu.version persist.sys.ksu.version \
                   ro.ksu.version persist.sukisu.version; do
        _dr_kv=""; _dr_kv=$(getprop "$_dr_kp" 2>/dev/null)
        [ -n "$_dr_kv" ] && { _dr_ksu="$_dr_kv ($_dr_kp)"; break; }
    done
    if [ -z "$_dr_ksu" ] && [ -f /data/adb/ksu/version ]; then
        read -r _dr_ksu < /data/adb/ksu/version 2>/dev/null
        _dr_ksu="$_dr_ksu (/data/adb/ksu/version)"
    fi
    echo "  Root     : ${_dr_ksu:-(未取到，可忽略)}"

    echo "== 2/8 内核能力 =="
    if spoof_supported; then
        echo "  emul_temp : ✓ 支持"
    else
        echo "  emul_temp : ✗ 不支持 —— 将回退「停服务 + 解频」激进模式，效果与风险都更高"
    fi
    _dr_wz=""
    for _dr_z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_dr_z/emul_temp" ] && { _dr_wz="$_dr_z/emul_temp"; break; }
    done
    if [ -n "$_dr_wz" ]; then
        [ -w "$_dr_wz" ] && echo "  写权限   : ✓ $_dr_wz" || echo "  写权限   : ✗ $_dr_wz 不可写（欺骗无法生效）"
    fi

    echo "== 3/8 温感命中 =="
    _dr_zt=0; _dr_ze=0; _dr_bl=0
    for _dr_z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_dr_z/temp" ] || continue
        _dr_zt=$((_dr_zt + 1))
        _dr_ty=""; read -r _dr_ty < "$_dr_z/type" 2>/dev/null
        [ -e "$_dr_z/emul_temp" ] && _dr_ze=$((_dr_ze + 1))
        is_blacklisted "$_dr_ty" && _dr_bl=$((_dr_bl + 1))
    done
    echo "  温感总数 : $_dr_zt"
    echo "  支持仿真 : $_dr_ze（不支持的 $((_dr_zt - _dr_ze)) 个，欺骗对它们无效）"
    echo "  黑名单   : $_dr_bl 个被排除"

    echo "== 4/8 欺骗状态 =="
    _dr_sc=0
    [ -s "$SPOOF_LIST" ] && _dr_sc=$(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ')
    case "$_dr_sc" in ''|*[!0-9]*) _dr_sc=0 ;; esac
    if [ "$_dr_sc" -gt 0 ]; then
        echo "  记账     : ✓ 已欺骗 $_dr_sc 个温感"
    else
        echo "  记账     : ✗ 空（欺骗未生效，或当前处于保护/安全模式）"
    fi
    _dr_state="unknown"
    [ -s "$STATE_FILE" ] && read -r _dr_state < "$STATE_FILE" 2>/dev/null
    echo "  当前状态 : $_dr_state"
    echo "  充电中   : $(get_charging 2>/dev/null)"

    echo "== 5/8 冲突检测 =="
    _dr_cf=$(detect_conflicts 2>/dev/null)
    if [ -z "$_dr_cf" ]; then
        echo "  ✓ 未检测到其他温控模块"
    else
        print_conflicts "  "
    fi

    echo "== 6/8 配置与保险丝 =="
    echo "  MODE     : $MODE"
    echo "  保险丝   : $([ "$FUSE_ENABLE" = "1" ] && echo "开启（累计触发 $(fuse_trips) 次）" || echo "关闭")"

    echo "== 7/8 安全与风险 =="
    _dr_risk=0
    if [ "$MODE" = "always" ] && [ "$SPOOF_BATT" = "1" ]; then
        echo "  ⚠ always 模式 + 电池欺骗开启：充电过温保护失效，只剩硬件熔断兜底"
        _dr_risk=$((_dr_risk + 1))
    fi
    if [ "$FUSE_ENABLE" != "1" ]; then
        echo "  ⚠ 温度保险丝已关闭：真实温度越界时不会自动回退原厂保护"
        _dr_risk=$((_dr_risk + 1))
    fi
    if safe_mode_active; then
        echo "  ⚠ 安全模式：温控已交还原厂（sh $MODDIR/action.sh dynamic 退出）"
        _dr_risk=$((_dr_risk + 1))
    fi
    [ "$STOP_SERVICES" = "1" ] && echo "  ⚠ STOP_SERVICES=1：性能/省电档位自动调节会失效"
    [ "$_dr_risk" = "0" ] && echo "  ✓ 未发现高风险配置"

    echo "== 8/8 依赖与权限 =="
    echo "  busybox   : $(command -v busybox >/dev/null 2>&1 && echo ✓ || echo '✗ 未找到（httpd 通道不可用）')"
    echo "  httpd     : $(command -v httpd >/dev/null 2>&1 && echo ✓ || { busybox httpd --help >/dev/null 2>&1 && echo '✓ (busybox httpd)' || echo '✗ 不可用'; })"
    echo "  日志文件  : $LOG_FILE"
    echo ""
    echo "（复制以上内容即可用于反馈问题）"
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
    # v2.8.13 优化（诊断路径，非热路径）：原来是 `$(cat|tr|tr)` = 3 fork + 每温感
    # 2 次 `$(cat)` ≈ 170 fork，`action.sh diag` 要跑几百 ms。全部 read 化零 fork，
    # 输出格式不变。CR 剥离用顶部 CR 变量（${var%"$CR"} 去行尾 \r，等价原 tr -d '\r'）。
    _dt_sl=" "
    while IFS= read -r _sl_ln || [ -n "$_sl_ln" ]; do
        [ -n "$_sl_ln" ] && _dt_sl="$_dt_sl${_sl_ln%"$CR"} "
    done < "$SPOOF_LIST" 2>/dev/null
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/temp" ] || continue
        _t="";  read -r _t  < "$_z/temp" 2>/dev/null
        _ty=""; read -r _ty < "$_z/type" 2>/dev/null
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
        _ty="";  read -r _ty  < "$_c/type"      2>/dev/null
        _cur=""; read -r _cur < "$_c/cur_state" 2>/dev/null
        _max=""; read -r _max < "$_c/max_state" 2>/dev/null
        _skip=""
        is_display_cdev "$_c/cur_state" && _skip=" ⚠显示类(已保护)"
        printf "  %-16s type=%-22s cur=%-4s max=%-4s%s\n" \
            "${_c##*/}" "${_ty:-?}" "$_cur" "$_max" "$_skip"
    done
}
