#!/system/bin/sh
# Thermal Horae Extreme WebUI API.
# Supports KernelSU exec mode and loopback CGI mode.

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) ;;
    *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="${SCRIPT_PATH%/*}"
WEBROOT_DIR="${SCRIPT_DIR%/*}"
MODDIR="${THERMAL_HORAE_MODDIR:-${WEBROOT_DIR%/*}}"
MODE_CONF="$MODDIR/mode.conf"
MODE_CONF_TMP="$MODDIR/.mode.conf.tmp"
LOCK_FILE="$MODDIR/.webui.lock"
LOG_TAG="thermal_horae_webui"
LOCK_TIMEOUT=10

json_header() {
    echo "Content-Type: application/json; charset=utf-8"
    echo "Cache-Control: no-cache, no-store, must-revalidate"
    echo "Pragma: no-cache"
    echo "Expires: 0"
    echo ""
}

json_error() {
    echo "{\"success\":false,\"message\":\"$1\"}"
}

log_msg() {
    command -v log >/dev/null 2>&1 && log -t "$LOG_TAG" "$1"
    return 0
}

get_config() {
    MODE="dynamic"
    STATIC_STATE="1"
    if [ -f "$MODE_CONF" ]; then
        MODE=$(sed -n 's/^MODE=//p' "$MODE_CONF" | head -n 1 | tr -d '[:space:]')
        STATIC_STATE=$(sed -n 's/^STATIC_STATE=//p' "$MODE_CONF" | head -n 1 | tr -d '[:space:]')
    fi
    case "$MODE" in static|dynamic) ;; *) MODE=dynamic ;; esac
    case "$STATIC_STATE" in 0|1) ;; *) STATIC_STATE=1 ;; esac
    echo "{\"MODE\":\"$MODE\",\"STATIC_STATE\":\"$STATIC_STATE\",\"version\":\"6.0.1\"}"
}

acquire_lock() {
    waited=0
    while [ -e "$LOCK_FILE" ] && [ "$waited" -lt "$LOCK_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    [ -e "$LOCK_FILE" ] && return 1
    (umask 077 && echo "$$" > "$LOCK_FILE") || return 1
    return 0
}

release_lock() {
    rm -f "$LOCK_FILE"
}

set_config() {
    NEW_MODE="$1"
    NEW_STATE="$2"
    [ "$NEW_MODE" = "static" ] || [ "$NEW_MODE" = "dynamic" ] || {
        json_error "无效的MODE参数，必须是static或dynamic"
        return 1
    }
    [ "$NEW_STATE" = "0" ] || [ "$NEW_STATE" = "1" ] || {
        json_error "无效的STATIC_STATE参数，必须是0或1"
        return 1
    }
    acquire_lock || {
        json_error "服务繁忙，请稍后重试"
        return 1
    }
    trap release_lock EXIT INT TERM
    if ! cat > "$MODE_CONF_TMP" << EOF
# Thermal Horae Extreme - 运行模式配置
# 由WebUI自动生成，请勿手动编辑
MODE=$NEW_MODE
STATIC_STATE=$NEW_STATE
EOF
    then
        json_error "写入配置文件失败"
        return 1
    fi
    if ! mv -f "$MODE_CONF_TMP" "$MODE_CONF"; then
        json_error "配置文件更新失败"
        return 1
    fi
    log_msg "config updated: MODE=$NEW_MODE STATIC_STATE=$NEW_STATE"
    echo '{"success":true,"message":"配置已保存，将在3秒内生效"}'
}

health_check() {
    SERVICE_RUNNING=0
    pgrep -f "$MODDIR/service.sh" >/dev/null 2>&1 && SERVICE_RUNNING=1
    MODULE_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)
    echo "{\"service_running\":$SERVICE_RUNNING,\"webui_version\":\"6.0.1\",\"module_version\":\"${MODULE_VERSION:-unknown}\"}"
}

# Direct mode is used by KernelSU's exec API and returns JSON only.
case "$1" in
    --get) get_config; exit 0 ;;
    --health) health_check; exit 0 ;;
    --set)
        [ "$#" -eq 3 ] || { json_error "参数数量错误"; exit 1; }
        set_config "$2" "$3"
        exit $?
        ;;
esac

# CGI mode is used by the Magisk fallback HTTP server.
json_header
if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    exit 0
fi

# Reject browser requests originating outside the loopback WebUI.
if [ "$REQUEST_METHOD" = "POST" ]; then
    case "$HTTP_ORIGIN" in
        ""|http://127.0.0.1:*|http://localhost:*) ;;
        *) json_error "拒绝跨站请求"; exit 0 ;;
    esac
    case "$HTTP_REFERER" in
        ""|http://127.0.0.1:*|http://localhost:*) ;;
        *) json_error "拒绝跨站请求"; exit 0 ;;
    esac
fi

case "$QUERY_STRING" in
    *action=get*) get_config ;;
    *action=health*) health_check ;;
    *action=set*)
        [ "$REQUEST_METHOD" = "POST" ] || { json_error "必须使用POST方法"; exit 0; }
        if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
            POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
        else
            read -r POST_DATA
        fi
        NEW_MODE=
        NEW_STATE=
        OLD_IFS=$IFS
        IFS='&'
        for field in $POST_DATA; do
            case "$field" in
                MODE=*) NEW_MODE=${field#MODE=} ;;
                STATIC_STATE=*) NEW_STATE=${field#STATIC_STATE=} ;;
            esac
        done
        IFS=$OLD_IFS
        set_config "$NEW_MODE" "$NEW_STATE" || true
        ;;
    *) json_error "未知操作，支持action=get|set|health" ;;
esac
