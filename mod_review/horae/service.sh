#!/system/bin/sh
# V6版改进：增加WebUI支持和静态/动态模式切换

MODDIR="${0%/*}"
GAME_LIST="$MODDIR/game_list.conf"
CAMERA_LIST="$MODDIR/camera_list.conf"
MODE_CONF="$MODDIR/mode.conf"
HORAE_PROP="persist.sys.horae.enable"
HORAE_SERVICE="horae"
POLL_SECONDS=3
LAST_PROBE=

export PATH="/system/bin:/system/xbin:/vendor/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin"

# 加载公共函数
. "$MODDIR/common_functions.sh"

# 读取运行模式配置
load_mode_config() {
    if [ ! -f "$MODE_CONF" ]; then
        # 默认配置
        RUN_MODE="dynamic"
        STATIC_STATE=1
        return
    fi
    
    RUN_MODE=$(grep '^MODE=' "$MODE_CONF" | cut -d= -f2)
    STATIC_STATE=$(grep '^STATIC_STATE=' "$MODE_CONF" | cut -d= -f2)
    
    [ -z "$RUN_MODE" ] && RUN_MODE="dynamic"
    [ -z "$STATIC_STATE" ] && STATIC_STATE=1
}

get_power_status() {
    for path in /sys/class/power_supply/*/status; do
        [ -f "$path" ] || continue
        status=$(cat "$path" 2>/dev/null)
        if [ "$status" = "Charging" ] || [ "$status" = "Full" ]; then
            echo 1
            return
        fi
    done
    echo 0
}

# 极简提取：用 grep 找行，用 cut/tr 提取包名
get_visible_apps() {
    VISIBLE_APPS=
    FOCUS_APP=
    
    activity_dump=$(dumpsys activity activities 2>/dev/null)
    
    # 提取包名的函数（纯 shell 字符串处理）
    extract_pkg() {
        local line="$1"
        # 查找 u数字 后面的内容
        local after_u=$(echo "$line" | grep -o 'u[0-9].*')
        if [ -n "$after_u" ]; then
            # 提取第一个空格后、斜杠前的内容
            echo "$after_u" | cut -d' ' -f2 | cut -d'/' -f1
        fi
    }
    
    # 方法1: topResumedActivity（优先级最高）
    top_line=$(echo "$activity_dump" | grep 'topResumedActivity=' | head -n 1)
    if [ -n "$top_line" ]; then
        FOCUS_APP=$(extract_pkg "$top_line")
        [ -n "$FOCUS_APP" ] && VISIBLE_APPS="$FOCUS_APP"
    fi
    
    # 方法2: mResumedActivity 和 ResumedActivity
    resumed_lines=$(echo "$activity_dump" | grep -E 'ResumedActivity')
    echo "$resumed_lines" | while read -r line; do
        [ -z "$line" ] && continue
        pkg=$(extract_pkg "$line")
        [ -n "$pkg" ] && echo "$pkg"
    done | while read -r pkg; do
        VISIBLE_APPS="$VISIBLE_APPS"$'\n'"$pkg"
    done
    
    # 方法3: 进程检测（最可靠）
    for pid_dir in /proc/[0-9]*; do
        [ -d "$pid_dir" ] || continue
        
        oom_file="$pid_dir/oom_score_adj"
        [ -f "$oom_file" ] || continue
        
        oom=$(cat "$oom_file" 2>/dev/null)
        [ -z "$oom" ] && continue
        
        # 只要前台和可见进程（数值 <= 100）
        if [ "$oom" -le 100 ] 2>/dev/null; then
            cmdline=$(cat "$pid_dir/cmdline" 2>/dev/null | tr '\000' '\n' | head -n 1)
            
            # 跳过系统进程和空值
            case "$cmdline" in
                ""|*:*|system_*|/system/*|/vendor/*|/apex/*) continue ;;
            esac
            
            # 只要看起来像包名的
            case "$cmdline" in
                *.*) VISIBLE_APPS="$VISIBLE_APPS"$'\n'"$cmdline" ;;
            esac
        fi
    done
    
    # 去重排序
    VISIBLE_APPS=$(echo "$VISIBLE_APPS" | grep '.' | sort -u)
    
    # 如果还没有焦点应用，从 window 获取
    if [ -z "$FOCUS_APP" ]; then
        focus_line=$(dumpsys window 2>/dev/null | grep 'mCurrentFocus=')
        FOCUS_APP=$(extract_pkg "$focus_line")
    fi
}

# 检查游戏：遍历可见应用列表
check_game_visible() {
    [ -z "$VISIBLE_APPS" ] && return 1
    
    GAME_APP=
    echo "$VISIBLE_APPS" | while read -r app; do
        [ -z "$app" ] && continue
        if is_in_list "$GAME_LIST" "$app"; then
            # 使用临时文件传递变量（子 shell 问题）
            echo "$app" > /data/local/tmp/.thermal_horae_game
            exit 0
        fi
    done
    
    # 读取结果
    if [ -f /data/local/tmp/.thermal_horae_game ]; then
        GAME_APP=$(cat /data/local/tmp/.thermal_horae_game)
        rm -f /data/local/tmp/.thermal_horae_game
        return 0
    fi
    return 1
}

# 检查相机：同上
check_camera_visible() {
    [ -z "$VISIBLE_APPS" ] && return 1
    
    CAMERA_APP=
    echo "$VISIBLE_APPS" | while read -r app; do
        [ -z "$app" ] && continue
        if is_in_list "$CAMERA_LIST" "$app"; then
            echo "$app" > /data/local/tmp/.thermal_horae_camera
            exit 0
        fi
    done
    
    if [ -f /data/local/tmp/.thermal_horae_camera ]; then
        CAMERA_APP=$(cat /data/local/tmp/.thermal_horae_camera)
        rm -f /data/local/tmp/.thermal_horae_camera
        return 0
    fi
    return 1
}

log_probe() {
    probe="$charging|$gaming|$camera|$FOCUS_APP|${GAME_APP:-none}|${CAMERA_APP:-none}"
    [ "$probe" = "$LAST_PROBE" ] && return
    LAST_PROBE="$probe"
    log -t thermal_horae "charging=$charging gaming=$gaming camera=$camera focus=${FOCUS_APP:-none} game=${GAME_APP:-none} cam=${CAMERA_APP:-none}"
}

apply_state() {
    desired="$1"
    current=$(getprop "$HORAE_PROP")
    service_state=$(getprop "init.svc.$HORAE_SERVICE")

    if [ "$desired" = 1 ]; then
        [ "$current" = 1 ] && [ "$service_state" = running ] && return
        setprop "$HORAE_PROP" 1
        [ "$service_state" = running ] || setprop ctl.start "$HORAE_SERVICE"
    else
        [ "$current" = 0 ] && [ "$service_state" = stopped ] && return
        setprop "$HORAE_PROP" 0
        [ "$service_state" = stopped ] || setprop ctl.stop "$HORAE_SERVICE"
    fi

    log -t thermal_horae "horae_enable=$desired (mode=$RUN_MODE charging=$charging gaming=$gaming camera=$camera)"
}

# 等待启动完成
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
done
sleep 5

log -t thermal_horae "service_started: static/dynamic mode support"

# 主循环
while true; do
    # 每次循环读取配置
    load_mode_config
    
    # 静态模式：直接应用固定状态
    if [ "$RUN_MODE" = "static" ]; then
        apply_state "$STATIC_STATE"
        sleep "$POLL_SECONDS"
        continue
    fi
    
    # 动态模式：原有检测逻辑
    charging=$(get_power_status)
    get_visible_apps
    
    gaming=0
    camera=0
    GAME_APP=
    CAMERA_APP=
    
    # 检测相机和游戏
    if check_camera_visible; then
        camera=1
    fi
    
    if check_game_visible; then
        gaming=1
    fi
    
    log_probe

    # 决策：相机 > 充电/游戏 > 默认
    if [ "$camera" = 1 ]; then
        apply_state 1
    elif [ "$charging" = 1 ] || [ "$gaming" = 1 ]; then
        apply_state 0
    else
        apply_state 1
    fi

    sleep "$POLL_SECONDS"
done
