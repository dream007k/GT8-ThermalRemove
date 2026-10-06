#!/system/bin/sh
# 独立温度欺骗脚本，可手动调用：
#   sh thermal_spoof.sh on    应用欺骗
#   sh thermal_spoof.sh off   撤销欺骗
#   sh thermal_spoof.sh show  打印各温感温度
MODDIR=${0%/*}
# 兜底：以相对路径调用时 ${0%/*} 拿不到目录
[ -d "$MODDIR/common" ] || MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
export MODDIR
export TR_SIDE_EFFECTS=1
[ -f "$MODDIR/common/functions.sh" ] && . "$MODDIR/common/functions.sh" || exit 1

load_conf

case "$1" in
    on)   apply_spoof; echo "欺骗已应用" ;;
    off)  restore_spoof; echo "欺骗已撤销" ;;
    show) dump_temp ;;
    *)    echo "用法: $0 on|off|show"; exit 1 ;;
esac
