#!/system/bin/sh
# 按需启动的 loopback WebUI 服务（busybox httpd）
MODDIR="${0%/*}"
# 兜底：以相对路径调用时 ${0%/*} 拿不到目录
[ -d "$MODDIR/common" ] || MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
PORT="${WEBUI_PORT:-37654}"
HOST="127.0.0.1"
PID_FILE="$MODDIR/.webui-httpd.pid"

is_running() {
    [ -f "$PID_FILE" ] || return 1
    _p=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

find_busybox() {
    for _bb in "$WEBUI_BUSYBOX" \
               /data/adb/ksu/bin/busybox \
               /data/adb/ksud/busybox \
               /data/adb/magisk/busybox \
               "$(command -v busybox 2>/dev/null)" \
               /system/bin/busybox \
               /system/xbin/busybox ; do
        [ -x "$_bb" ] || continue
        "$_bb" --list 2>/dev/null | grep -qx httpd || continue
        echo "$_bb"
        return 0
    done
    return 1
}

is_running && exit 0
rm -f "$PID_FILE"

BUSYBOX=$(find_busybox) || {
    command -v log >/dev/null 2>&1 && log -t gt8_thermal "WebUI: busybox httpd 不可用"
    exit 1
}

cd "$MODDIR/webroot" || exit 1
"$BUSYBOX" httpd -f -p "${HOST}:${PORT}" -h "$MODDIR/webroot" > /dev/null 2>&1 &
_pid=$!
echo "$_pid" > "$PID_FILE"
sleep 1
kill -0 "$_pid" 2>/dev/null && exit 0

rm -f "$PID_FILE"
exit 1
