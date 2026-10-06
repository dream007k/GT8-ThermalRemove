#!/system/bin/sh
# post-fs-data（早期阶段）：
#   · 只做一轮早期温度欺骗（让充电判定等早期路径读到低温）
#   · 配置改写的 bind 挂载统一放到 service.sh（等所有 overlay 就位后再挂，
#     否则会被后续挂载覆盖 —— Extreme GT 的经验）
MODDIR=${0%/*}
# 兜底：${0%/*} 在极端调用方式下可能拿不到目录，common/ 是可靠的模块根标记
[ -d "$MODDIR/common" ] || MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
export MODDIR
export TR_SIDE_EFFECTS=1
. "$MODDIR/common/functions.sh"
# v2.10.0：先解析配置再打首行日志，让日志级别从一开始就生效
load_conf
log_info "==== post-fs-data 开始 ===="

# 早期阶段不做配置挂载（SKIP_MOUNT），避免被后续 overlay 覆盖或重复叠加
SKIP_MOUNT=1

# ── v2.12.0：开机自救（boot token）─────────────────────────────
# 每次 post-fs-data 递增计数，boot-completed 清零。连续 BOOT_FAIL_LIMIT 次没走到
# boot-completed，说明上一轮的配置很可能导致异常（崩溃 / 卡开机）→ 自动安全模式，
# 把温控完全交还原厂，保证设备一定能进系统。
_boot_try=$(boot_token_bump)
if [ "$_boot_try" -ge "${BOOT_FAIL_LIMIT:-3}" ] 2>/dev/null; then
    log_warn "! 连续 $_boot_try 次开机未完成，判定为异常启动 → 自动进入安全模式（MODE=off）"
    log_warn "  温控已交还原厂；确认设备稳定后用 sh action.sh dynamic 重新启用"
    panic_to_safe
    log_info "==== post-fs-data 结束（安全模式）===="
    exit 0
fi

# ── v2.12.0：早期阶段按「决策结果」应用，而不是硬编码移除 ────────
# 原实现 `[ "$MODE" != "off" ] && apply_state 1`：dynamic 模式下若开机时正插着
# 充电器，这个早期窗口（到 service.sh 主循环接管前的 20~60 秒）会**先移除温控**，
# 充电过温保护在这段时间里缺失。decide_state_into 零 fork，早期可以直接调用。
if [ "$MODE" != "off" ]; then
    decide_state_into 0
    [ "$DECIDE_RESULT" = "1" ] && apply_state 1
fi

log_info "==== post-fs-data 结束 ===="
exit 0
