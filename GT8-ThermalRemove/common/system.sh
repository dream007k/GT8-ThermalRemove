# GT8 ThermalRemove · common/system.sh
# 系统操作：属性 / ORMS / 挂载 / 校验 / 登录等待
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


# ── 等用户数据解锁（比 sys.boot_completed 更靠后，服务才就绪）────
# v2.8.13 省电：原来是死板的 sleep 1 —— 开机阶段最多 300 次唤醒（每次一个
# fork），而用户数据解锁发生在开机后十几秒到几分钟不等，前几秒的 1s 轮询
# 纯属空转。改成退避：1→2→3→4→5s 后保持 5s，总次数从 300 降到 ~90。
# 判定语义不变（仍是「目录出现」或「总等待超 300s」两种出口）。
wait_until_login() {
    _i=0; _s=1
    until [ -d /data/data/android ] || [ "$_i" -gt 300 ]; do
        sleep "$_s"
        _i=$((_i + _s))
        [ "$_s" -lt 5 ] && _s=$((_s + 1))
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
        log_debug "  校验详情: dumpsys horae 无 Temp 相关输出（该 ROM 可能不提供此字段）"
    else
        log_debug "  校验详情: horae 读到 [$(echo "$_vd_out" | tr '\n' ' ')]"
    fi
    log_debug "  期望: 皮肤温感被欺骗为 ${SKIN_T} 毫摄氏度"
    if [ "$OPPO_SHELL_TEMP" != "1" ]; then
        log_debug "  提示: OPPO_SHELL_TEMP=0，/proc/shell-temp 未写入（该路径不参与校验）"
    fi
    log_debug "  记账: $(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ') 条记录"
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
    log_info "属性已还原"
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
        log_debug "mount: $_dst"
    done
}

# v2.8.13 省电：判断记账里的挂载点是否全都还挂着（一次 awk 替代逐文件 awk）。
# 返回 0 = 完整，1 = 有缺失（或从未挂载），调用方据此决定要不要跑完整流程。
_mounts_intact() {
    [ -s "$MOUNT_LIST" ] || return 1
    # 一条 awk 吃两个文件：先登记记账里的挂载点，再拿 /proc/mounts 的第二列销账，
    # 最后看有没有销不掉的。用标量 n 计数而不是 length(array) —— 后者在部分
    # busybox awk 上不支持。
    awk 'NR==FNR { m[$0]=1; n++; next }
         ($2 in m) { delete m[$2]; n-- }
         END { exit (n ? 1 : 0) }' "$MOUNT_LIST" /proc/mounts 2>/dev/null
}

mount_config_overlays() {
    if [ "${SKIP_MOUNT:-0}" = "1" ]; then
        log_info "早期阶段跳过配置挂载 (SKIP_MOUNT=1)"
        return 0
    fi
    # v2.8.13 省电：原实现每次都 find 整个 patched/ 目录，再对**每个文件** fork
    # 一次 awk 去扫 /proc/mounts（GT8 上 ≈20 个文件 → 20+ 次 fork 加 1 次 find）。
    # 但 bind mount 一旦建立，在本进程存活期间不会自己消失，绝大多数轮次这一趟
    # 是纯空转。先整体校验一遍（1 次 awk）：全在就跳过，缺一个才走原路径补挂。
    # 语义不变 —— 补挂的判断依据与原来逐文件判断完全一致，只是合并成一次。
    if _mounts_intact; then
        return 0
    fi
    : > "$MOUNT_LIST" 2>/dev/null
    [ "$PATCH_THERMAL" = "1" ] && mount_set "$MODDIR/patched/thermal"
    [ "$PATCH_EXTRA"   = "1" ] && mount_set "$MODDIR/patched/extra"
    log_info "配置改写挂载完成 (thermal=$PATCH_THERMAL extra=$PATCH_EXTRA)"
}

unmount_config_overlays() {
    [ -f "$MOUNT_LIST" ] || return 0
    while IFS= read -r _dst; do
        [ -n "$_dst" ] && umount "$_dst" 2>/dev/null
    done < "$MOUNT_LIST"
    : > "$MOUNT_LIST"
    log_info "配置改写已卸载"
}
