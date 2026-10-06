#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════
#  schema.sh —— 配置键的「唯一事实源」（v2.13.2 / A2）
#
#  新增/修改配置键时**只改这个文件**，不要再动 functions.sh 的 load_conf、
#  api.sh 的 do_set、presets.sh 的三个函数。三处都从这里查：
#
#    schema_file KEY        写 _SC_FILE（mode|spoof），非白名单返回 1
#    schema_default KEY     写 _SC_DEF（默认值），无默认返回 1
#    schema_valid KEY VALUE 合法返回 0，非法返回 1
#    schema_apply_defaults  批量初始化 load_conf 消费的键（内部受控 eval）
#
#  纯函数、零副作用、零 fork，可被任意入口 source（幂等，只定义函数）。
#  两个清单：
#    SCHEMA_KEYS     配置键全集（用于回归完整性断言）
#    LOAD_CONF_KEYS  load_conf 需要初始化并消费的子集 —— api.sh 专用的
#                    SHOW_REAL_TEMP / REAL_TEMP_DELAY_MS / RUNTIME_SNAPSHOT /
#                    CHECK_KNOWN_CFG 不在其中（它们由 api.sh 直接 conf_get）。
# ═══════════════════════════════════════════════════════════════

SCHEMA_KEYS="MODE GAME_PROTECT STOP_SERVICES UNLOCK_FREQ UNLOCK_GPU GPU_MAX_CLK PATCH_THERMAL PATCH_EXTRA UNLOCK_CDEV DISPLAY_PROTECT OPPO_SHELL_TEMP OPPO_GAUGE HORAE_TESTMODE DISABLE_ORMS TOUCH_BOOST TOUCH_THREAD_BOOST TOUCH_THREAD_NICE CHECK_CONFLICTS SCAN_RESOURCES LOG_LEVEL MAINT_SECONDS PERF_REFRESH_SECONDS LOG_HEARTBEAT CONF_FORCE_TICKS REPLACE_ENCRYPTED SHOW_REAL_TEMP REAL_TEMP_DELAY_MS RUNTIME_SNAPSHOT CHECK_KNOWN_CFG FUSE_ENABLE FUSE_COOLDOWN BOOT_FAIL_LIMIT FUSE_TEMP_BATT FUSE_TEMP_SOC FUSE_TEMP_SKIN AUTO_GAME_PRESET SPOOF_BATT SOC_T SKIN_T CAM_T BATT_T SHELL_PROC_T BLACKLIST"

LOAD_CONF_KEYS="MODE GAME_PROTECT STOP_SERVICES UNLOCK_FREQ UNLOCK_GPU GPU_MAX_CLK PATCH_THERMAL PATCH_EXTRA UNLOCK_CDEV DISPLAY_PROTECT OPPO_SHELL_TEMP OPPO_GAUGE HORAE_TESTMODE DISABLE_ORMS TOUCH_BOOST TOUCH_THREAD_BOOST TOUCH_THREAD_NICE CHECK_CONFLICTS SCAN_RESOURCES LOG_LEVEL MAINT_SECONDS PERF_REFRESH_SECONDS LOG_HEARTBEAT CONF_FORCE_TICKS REPLACE_ENCRYPTED FUSE_ENABLE FUSE_COOLDOWN BOOT_FAIL_LIMIT FUSE_TEMP_BATT FUSE_TEMP_SOC FUSE_TEMP_SKIN AUTO_GAME_PRESET SPOOF_BATT SOC_T SKIN_T CAM_T BATT_T SHELL_PROC_T BLACKLIST"

# 归属文件：mode.conf 还是 spoof.conf
schema_file() {
    case "$1" in
        MODE|GAME_PROTECT|STOP_SERVICES|UNLOCK_FREQ|UNLOCK_GPU|GPU_MAX_CLK|\
PATCH_THERMAL|PATCH_EXTRA|UNLOCK_CDEV|DISPLAY_PROTECT|OPPO_SHELL_TEMP|OPPO_GAUGE|\
HORAE_TESTMODE|DISABLE_ORMS|TOUCH_BOOST|TOUCH_THREAD_BOOST|TOUCH_THREAD_NICE|\
CHECK_CONFLICTS|SCAN_RESOURCES|LOG_LEVEL|MAINT_SECONDS|PERF_REFRESH_SECONDS|\
LOG_HEARTBEAT|CONF_FORCE_TICKS|REPLACE_ENCRYPTED|SHOW_REAL_TEMP|REAL_TEMP_DELAY_MS|\
RUNTIME_SNAPSHOT|CHECK_KNOWN_CFG|FUSE_ENABLE|FUSE_COOLDOWN|BOOT_FAIL_LIMIT|\
FUSE_TEMP_BATT|FUSE_TEMP_SOC|FUSE_TEMP_SKIN|AUTO_GAME_PRESET)
            _SC_FILE=mode; return 0 ;;
        SPOOF_BATT|SOC_T|SKIN_T|CAM_T|BATT_T|SHELL_PROC_T|BLACKLIST)
            _SC_FILE=spoof; return 0 ;;
    esac
    return 1
}

# 默认值（与 load_conf 语义一致：空值/缺键回落这里）
schema_default() {
    case "$1" in
        MODE)               _SC_DEF=dynamic ;;
        LOG_LEVEL)          _SC_DEF=info ;;
        GPU_MAX_CLK)        _SC_DEF=2147483647 ;;
        MAINT_SECONDS)      _SC_DEF=120 ;;
        PERF_REFRESH_SECONDS) _SC_DEF=30 ;;
        LOG_HEARTBEAT)      _SC_DEF=12 ;;
        CONF_FORCE_TICKS)   _SC_DEF=12 ;;
        TOUCH_THREAD_NICE)  _SC_DEF=-19 ;;
        REAL_TEMP_DELAY_MS) _SC_DEF=80 ;;
        FUSE_TEMP_BATT)     _SC_DEF=45000 ;;
        FUSE_TEMP_SOC)      _SC_DEF=80000 ;;
        FUSE_TEMP_SKIN)     _SC_DEF=46000 ;;
        FUSE_COOLDOWN)      _SC_DEF=120 ;;
        BOOT_FAIL_LIMIT)    _SC_DEF=3 ;;
        SOC_T|SKIN_T|CAM_T|BATT_T|SHELL_PROC_T) _SC_DEF=29500 ;;
        BLACKLIST)          _SC_DEF="" ;;
        SPOOF_BATT|FUSE_ENABLE|UNLOCK_FREQ|PATCH_THERMAL|TOUCH_BOOST|UNLOCK_GPU|\
DISPLAY_PROTECT|CHECK_CONFLICTS|SHOW_REAL_TEMP|RUNTIME_SNAPSHOT|CHECK_KNOWN_CFG)
            _SC_DEF=1 ;;
        GAME_PROTECT|STOP_SERVICES|OPPO_SHELL_TEMP|OPPO_GAUGE|HORAE_TESTMODE|\
DISABLE_ORMS|UNLOCK_CDEV|TOUCH_THREAD_BOOST|PATCH_EXTRA|SCAN_RESOURCES|\
REPLACE_ENCRYPTED|AUTO_GAME_PRESET)
            _SC_DEF=0 ;;
        *) return 1 ;;
    esac
    return 0
}

# 值域校验：合法返回 0，非法返回 1（写入前校验用；load_conf 的运行时净化另有一套回落）
schema_valid() {
    _sv_k="$1"; _sv_v="$2"
    case "$_sv_k" in
        MODE)      case "$_sv_v" in dynamic|always|off) return 0 ;; esac; return 1 ;;
        LOG_LEVEL) case "$_sv_v" in debug|info|warn|error) return 0 ;; esac; return 1 ;;
        BLACKLIST) return 0 ;;   # 空格分隔的通配符列表，任意值
        SOC_T|SKIN_T|CAM_T|BATT_T|SHELL_PROC_T)
            case "$_sv_v" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_sv_v" -le 100000 ] && return 0; return 1 ;;
        GPU_MAX_CLK)
            case "$_sv_v" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_sv_v" -ge 1 ] && [ "$_sv_v" -le 2147483647 ] && return 0; return 1 ;;
        TOUCH_THREAD_NICE)
            case "$_sv_v" in ''|*[!0-9-]*) return 1 ;; esac
            [ "$_sv_v" -ge -20 ] 2>/dev/null && [ "$_sv_v" -le 19 ] 2>/dev/null && return 0; return 1 ;;
        MAINT_SECONDS|FUSE_COOLDOWN)
            case "$_sv_v" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_sv_v" -ge 5 ] && [ "$_sv_v" -le 86400 ] && return 0; return 1 ;;
        PERF_REFRESH_SECONDS|CONF_FORCE_TICKS|LOG_HEARTBEAT|REAL_TEMP_DELAY_MS)
            case "$_sv_v" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_sv_v" -le 86400 ] && return 0; return 1 ;;
        FUSE_TEMP_BATT|FUSE_TEMP_SOC|FUSE_TEMP_SKIN)
            case "$_sv_v" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_sv_v" -le 120000 ] && return 0; return 1 ;;
        BOOT_FAIL_LIMIT)
            case "$_sv_v" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_sv_v" -ge 1 ] && [ "$_sv_v" -le 20 ] && return 0; return 1 ;;
    esac
    case "$_sv_v" in 0|1) return 0 ;; esac   # 其余一律 0/1 开关
    return 1
}

# 预设是否可接管该键（预设引擎的约束 3：个性化键/内部调优键不接管）
# 区别于 schema_file 的「归属全集」——do_set / load_conf 用全集，预设用这个子集。
schema_preset_ok() {
    case "$1" in
        BLACKLIST|SHOW_REAL_TEMP|TOUCH_THREAD_NICE|REPLACE_ENCRYPTED|\
REAL_TEMP_DELAY_MS|RUNTIME_SNAPSHOT|CHECK_KNOWN_CFG|AUTO_GAME_PRESET)
            return 1 ;;
    esac
    return 0
}

# 批量初始化 load_conf 消费的键。
# eval 的参数全部来自上方静态 case（键名来自 LOAD_CONF_KEYS 常量、值来自
# schema_default 的静态返回），没有任何用户输入进入 eval —— 无注入面。
schema_apply_defaults() {
    for _sk in $LOAD_CONF_KEYS; do
        schema_default "$_sk" || continue
        eval "$_sk=\$_SC_DEF"
    done
    return 0
}
