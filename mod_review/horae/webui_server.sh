#!/system/bin/sh
# On-demand loopback WebUI server for Magisk's action button.

MODDIR="${0%/*}"
PORT="${WEBUI_PORT:-37654}"
HOST="127.0.0.1"
PID_FILE="$MODDIR/.webui-httpd.pid"

log_webui() {
    log -t thermal_horae "$1" 2>/dev/null || true
}

is_running() {
    [ -f "$PID_FILE" ] || return 1
    PID=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null
}

find_busybox() {
    BUSYBOX_IN_PATH=$(command -v busybox 2>/dev/null)
    for busybox in \
        "$WEBUI_BUSYBOX" \
        /data/adb/magisk/busybox \
        "$BUSYBOX_IN_PATH" \
        /data/adb/ksu/bin/busybox \
        /data/adb/ksud/busybox \
        /system/bin/busybox \
        /system/xbin/busybox; do
        [ -x "$busybox" ] || continue
        "$busybox" --list 2>/dev/null | grep -qx httpd || continue
        echo "$busybox"
        return 0
    done
    return 1
}

if is_running; then
    exit 0
fi
rm -f "$PID_FILE"

BUSYBOX=$(find_busybox) || {
    log_webui "WebUI disabled: BusyBox httpd is unavailable"
    exit 1
}

cd "$MODDIR/webroot" || exit 1
# -f keeps httpd attached to the background PID; bind only to loopback.
"$BUSYBOX" httpd -f -p "${HOST}:${PORT}" -h "$MODDIR/webroot" > /dev/null 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"
sleep 1
if kill -0 "$PID" 2>/dev/null; then
    log_webui "WebUI started on http://${HOST}:${PORT}"
    exit 0
fi

rm -f "$PID_FILE"
log_webui "WebUI failed to start"
exit 1
