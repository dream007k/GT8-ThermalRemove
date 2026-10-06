#!/system/bin/sh
# 卸载：撤销欺骗、还原 sysfs、停掉 WebUI 与主循环
MODDIR=${0%/*}
# 兜底：以相对路径调用时 ${0%/*} 拿不到目录
[ -d "$MODDIR/common" ] || MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
export MODDIR

if [ -f "$MODDIR/common/functions.sh" ]; then
    export TR_SIDE_EFFECTS=1
    . "$MODDIR/common/functions.sh"
    load_conf
    restore_spoof
    restore_sysfs
    restore_props
    orms_on
    # v2.8.8：必须在后面 rm -rf /data/adb/thermal_remove 之前还原 ——
    # 原 nice 值的备份就存在那个目录里，删掉就还原不回去了
    touch_thread_restore
    rm -f "$STATE_FILE"
    log_info "==== 模块已卸载，温控完全还原 ===="
fi

# 停掉 WebUI
[ -f "$MODDIR/.webui-httpd.pid" ] && {
    kill "$(cat "$MODDIR/.webui-httpd.pid" 2>/dev/null)" 2>/dev/null
    rm -f "$MODDIR/.webui-httpd.pid"
}

# 停掉主循环
pkill -f "$MODDIR/service.sh" 2>/dev/null

# v2.8.7：/data/system 显示配置的「首次快照」刻意保留下来，不跟着一起删。
# 它存在的意义就是应对「别的模块 sed -i 改坏了配置、又没有卸载脚本」——
# 而这种事恰恰最可能发生在你卸载本模块、换别的模块之后。
# 快照很小（几百 KB）且从不写入；确认不需要就手动执行下面这行清掉：
#     rm -rf /data/adb/thermal_remove
if [ -d /data/adb/thermal_remove/runtime_backup ]; then
    mkdir -p /data/adb/.tr_keep 2>/dev/null &&
        mv -f /data/adb/thermal_remove/runtime_backup /data/adb/.tr_keep/ 2>/dev/null
fi

rm -rf /data/adb/thermal_remove 2>/dev/null

if [ -d /data/adb/.tr_keep/runtime_backup ]; then
    mkdir -p /data/adb/thermal_remove 2>/dev/null
    mv -f /data/adb/.tr_keep/runtime_backup /data/adb/thermal_remove/ 2>/dev/null
    rm -rf /data/adb/.tr_keep 2>/dev/null
    echo "已保留 /data/adb/thermal_remove/runtime_backup（显示配置快照，可手动删除）"
fi
exit 0
