#!/system/bin/sh
# 开机完成后补一次：部分厂商服务会在此时重新拉起并重置 sysfs
MODDIR=${0%/*}
# 兜底：${0%/*} 在极端调用方式下可能拿不到目录，common/ 是可靠的模块根标记
[ -d "$MODDIR/common" ] || MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
export MODDIR
export TR_SIDE_EFFECTS=1
. "$MODDIR/common/functions.sh"
# v2.10.0：先解析配置再打首行日志，让日志级别从一开始就生效
load_conf
log_info "==== boot-completed ===="

# v2.12.0：开机完成 → 清掉尝试计数（下次异常启动重新从 0 计），
# 并顺手清理 CGI 遗留的临时文件（低频；只删本模块前缀且 2 小时以上未修改的）。
boot_token_clear
cleanup_stale_tmp
safe_mode_active && log_warn "当前处于安全模式（MODE=off）：温控已交还原厂，欺骗不会应用"

if [ "$MODE" = "off" ]; then
    apply_state 0
else
    apply_state 1
fi

log_info "boot-completed 完成"
exit 0
