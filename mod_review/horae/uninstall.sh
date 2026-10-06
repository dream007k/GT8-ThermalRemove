#!/system/bin/sh
MODDIR="${0%/*}"
PID_FILE="$MODDIR/.webui-httpd.pid"
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -f "$PID_FILE"
fi
setprop persist.sys.horae.enable 1
exit 0
