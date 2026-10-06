#!/system/bin/sh
# 主守护：挂载 overlay → 场景检测 → 应用/撤销温度欺骗 → 持续压制内核写回
MODDIR=${0%/*}
# 兜底：${0%/*} 在极端调用方式下可能拿不到目录，common/ 是可靠的模块根标记
[ -d "$MODDIR/common" ] || MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
export MODDIR
# v2.9.3：本入口需要写盘（建目录/写日志），显式打开 source-time 副作用。
export TR_SIDE_EFFECTS=1
. "$MODDIR/common/functions.sh"

# v2.8.13 健壮性：标记本进程为「长驻守护」。
# load_conf / _he_refresh 的缓存时间戳（.conf_stamp / .list_stamp）只在本进程打，
# 避免一次性进程（action.sh status 等）完整解析后把共享 stamp 刷成「现在」，
# 导致主进程对「稍早的配置改动」漏检一次（最多 60s）。见 functions.sh 的 load_conf。
export CONF_PERSISTENT=1

log_info "==== service 启动 (v2.13.3, Android ${ANDROID_REL:-?}) ===="
load_conf

# v2.8：模块冲突自检（只写日志，不改任何状态、不阻断启动）
log_conflicts

# 内核不支持 emul_temp 时，自动切到兜底手段（停服务 + 解频）
if ! spoof_supported; then
    log_warn "! 未发现 emul_temp 节点，回退激进模式"
    sed -i 's/^STOP_SERVICES=.*/STOP_SERVICES=1/' "$MODE_CONF" 2>/dev/null
    sed -i 's/^UNLOCK_FREQ=.*/UNLOCK_FREQ=1/' "$MODE_CONF" 2>/dev/null
fi

# 配置改写的挂载放在 service.sh（等所有 overlay 就位后再挂，否则会被覆盖）
mount_overlays() {
    mount_config_overlays
}

# 欺骗自检：以模块记账 spoof.list 为准（v2.8.5）
# 原实现用 dumpsys horae 的温度值做判定，但期望值取错了来源、且行首匹配过严，
# 在真机上必然误判失败（实机日志：83 个温感已应用成功，校验却连续失败两次）。
# 现在：记账非空即视为生效；失败时输出可定位的诊断信息。
verify_and_recover() {
    [ "$MODE" = "off" ] && return 0
    if verify_spoof; then
        log_info "✓ 欺骗校验通过（记账 $(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ') 条温感）"
    else
        log_warn "! 欺骗校验未通过（记账为空），补一次应用"
        verify_spoof_detail
        apply_state 1
        sleep 5
        if verify_spoof; then
            log_info "✓ 补应用后校验通过"
        else
            log_error "补应用后仍为空：模块核心功能（温度欺骗）未能生效，请检查内核是否支持 emul_temp、是否被其它模块抢占"
            verify_spoof_detail
        fi
    fi
}

main_loop() {
    # v2.8.13 省电：开机等待改为退避（原来死等 sleep 1，且每次 getprop 一个 fork）
    _bs=1
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep "$_bs"
        [ "$_bs" -lt 5 ] && _bs=$((_bs + 1))
    done
    mount_overlays
    wait_until_login
    log_info "开机完成，进入主循环 (mode=$MODE)"

    # 首轮：HORAE testmode + 欺骗
    load_conf
    decide_state_into 0
    apply_state "$DECIDE_RESULT"

    _tick=0
    _maint_acc=0          # 距上次完整维护累计秒数
    _perf_acc=0           # 距上次 reapply_perf 累计秒数
    while true; do
        load_conf
        decide_state_into 0
        _want=$DECIDE_RESULT
        # v2.8.12 性能：read 是内建命令，读首行零 fork（原 $(cat) 每轮 1 次 fork）
        _cur=""; read -r _cur < "$STATE_FILE" 2>/dev/null

        if [ "$_want" = "1" ]; then
            if [ "$_cur" != "on" ]; then
                # ── 状态切换：走完整流程，与 v2.8.12 完全一致 ──
                apply_state 1
                _maint_acc=0; _perf_acc=0
            else
                # ── 状态没变：检测仍是 5s，重活按秒降频 ──
                # 原实现这里每 6 个 tick（30s）跑一次完整 apply_state，把
                # find / 逐文件 awk / 逐核 sysfs_set / 83 个温感 cat / pidof
                # 全跑一遍（≈177 次 fork），而状态没变时其中绝大多数是空转。
                # 现在拆成两个独立预算：
                #   MAINT_SECONDS（120s）      完整轻维护：重放欺骗值 + 补提权 + 校验挂载
                #   PERF_REFRESH_SECONDS（30s） 只做 reapply_perf（零 fork 的 16 次 sysfs 读）
                _maint_acc=$((_maint_acc + POLL_SECONDS))
                _perf_acc=$((_perf_acc + POLL_SECONDS))
                if [ "$_maint_acc" -ge "$MAINT_SECONDS" ]; then
                    maintain_state
                    _perf_acc=0
                    if [ "${_SPOOF_FAILED:-0}" = "1" ]; then
                        # 欺骗重放全失败：让下次维护提前一个 tick 就重试（自愈）
                        _maint_acc=$((MAINT_SECONDS - POLL_SECONDS))
                    else
                        _maint_acc=0
                    fi
                elif [ "$PERF_REFRESH_SECONDS" -gt 0 ] && \
                     [ "$_perf_acc" -ge "$PERF_REFRESH_SECONDS" ]; then
                    reapply_perf
                    _perf_acc=0
                fi
            fi
            # 开机约 60s 做一次欺骗自检：挂在主循环里，不再另开后台子 shell
            # （单一轮询点约束 —— 见 functions.sh 顶部说明）
            [ "$_tick" = "$VERIFY_TICK" ] && verify_and_recover
        else
            [ "$_cur" != "off" ] && apply_state 0
            _maint_acc=0; _perf_acc=0
        fi

        _tick=$((_tick + 1))
        sleep "$POLL_SECONDS"
    done
}

main_loop &
exit 0
