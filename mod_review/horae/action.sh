#!/system/bin/sh
# Magisk action button entry for the WebUI.

MODDIR="${0%/*}"
PORT=37654
URL="http://127.0.0.1:${PORT}/"

print_msg() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$1"
    else
        echo "$1"
    fi
}

WEBUI_PORT="$PORT" "$MODDIR/webui_server.sh" || {
    print_msg "无法启动 WebUI：设备上未找到支持 httpd 的 BusyBox"
    exit 1
}

if command -v am >/dev/null 2>&1; then
    am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
    print_msg "已打开 Thermal Horae WebUI"
else
    print_msg "请在浏览器中打开：$URL"
fi
