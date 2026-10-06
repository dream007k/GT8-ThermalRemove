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

# 帮助文案（v2.17.5 / U4）：每个键一句「这是什么 + 设了会怎样 + 建议」。
# 与 file/default/valid 同源 —— WebUI 的 ⓘ 内联说明、未来可能的 doctor 提示都从这里取，
# 避免「前端硬编码一份、后端再写一份」的文案漂移。
# 写 _SC_HELP；非白名单返回 1。
schema_help() {
    case "$1" in
        MODE)        _SC_HELP="运行模式。dynamic=充电/保护名单时自动恢复原厂温控（推荐）；always=始终去温控；off=等同原厂" ;;
        GAME_PROTECT) _SC_HELP="游戏时是否保留原厂温控。1=进游戏恢复保护（保守，可能压帧）；0=游戏时也去温控（满血）" ;;
        STOP_SERVICES) _SC_HELP="停用 thermal 相关服务（极端兜底）。仅当欺骗失效、温控仍在压频时开启；会连 perf 守护进程一起 kill，性能档可能失效" ;;
        UNLOCK_FREQ) _SC_HELP="解锁 CPU/GPU 频率上限（核心去温控手段之一）。默认开" ;;
        UNLOCK_GPU)  _SC_HELP="是否解锁 GPU 频率。配合 GPU_MAX_CLK 甜点值平衡功耗/发热" ;;
        GPU_MAX_CLK) _SC_HELP="GPU 频率甜点值（MHz）。SM8750 上真正生效的是 devfreq 的 max_freq，改完应以 devfreq/cur_freq 确认" ;;
        PATCH_THERMAL) _SC_HELP="安装时改写核心温控配置（HORAE 成熟规则）。默认开" ;;
        PATCH_EXTRA) _SC_HELP="扩展配置改写（含 oppo_display_perf_list.xml）。⚠ 与亮度/性能相关，默认关" ;;
        UNLOCK_CDEV) _SC_HELP="强制归零 cooling_device。⚠ 会误伤背光类节点、压低亮度，默认关" ;;
        DISPLAY_PROTECT) _SC_HELP="显示/背光类冷却节点永久保护。务必保持开启，否则亮度可能被压到最低" ;;
        OPPO_SHELL_TEMP) _SC_HELP="写 /proc/shell-temp 外壳温度。⚠ 与屏幕亮度直接相关，默认关" ;;
        OPPO_GAUGE)  _SC_HELP="写 oplus-votable GAUGE_UPDATE。作用不明确，不建议开" ;;
        HORAE_TESTMODE) _SC_HELP="调用 OPPO HORAE testmode（dumpsys）。进阶手段，默认关" ;;
        DISABLE_ORMS) _SC_HELP="停用 OPPO ORMS 资源/温控管理服务。默认关" ;;
        TOUCH_BOOST) _SC_HELP="触控服务 renice -19（厂商触控守护进程提权）。默认开" ;;
        TOUCH_THREAD_BOOST) _SC_HELP="inputflinger 线程提权（InputReader/Dispatcher 的 nice，非实时）。仅 Android 12+ 有效，默认关" ;;
        TOUCH_THREAD_NICE) _SC_HELP="inputflinger 线程提权的目标 nice（默认 -19）" ;;
        CHECK_CONFLICTS) _SC_HELP="模块冲突自检（安装期 + 运行时 + WebUI）。只告警不阻断，默认开" ;;
        SCAN_RESOURCES) _SC_HELP="Tier C 按资源占用扫描第三方模块（翻开其脚本查关键字）。默认关，安装期与 conflicts 自动开" ;;
        LOG_LEVEL)   _SC_HELP="日志级别：debug=最详细 / info=默认 / warn=仅异常 / error=仅核心失效" ;;
        MAINT_SECONDS) _SC_HELP="完整维护周期（秒）。默认 120；设 30 即回到早期节奏（更耗电但更及时）" ;;
        PERF_REFRESH_SECONDS) _SC_HELP="只做频率锁压制（reapply_perf）的周期（秒）。0=只在维护时做" ;;
        LOG_HEARTBEAT) _SC_HELP="欺骗重放日志：每 N 次维护记一条。0=只在条数变化时记" ;;
        CONF_FORCE_TICKS) _SC_HELP="配置缓存强制刷新周期（tick 数）。默认 12" ;;
        REPLACE_ENCRYPTED) _SC_HELP="非明文 sys_thermal_control_config 整体替换。仅安装/升级时读取，运行中改无效" ;;
        SHOW_REAL_TEMP) _SC_HELP="是否允许 WebUI 读取真实温度（手动触发）。默认开" ;;
        REAL_TEMP_DELAY_MS) _SC_HELP="真实温度探测第一轮等待（毫秒）。读不到会自动 320/800ms 重试" ;;
        RUNTIME_SNAPSHOT) _SC_HELP="/data/system 显示配置「首次快照」。改坏时可用 rr_restore 一键还原" ;;
        CHECK_KNOWN_CFG) _SC_HELP="安装期核对 12 个已知配置文件名，结果写入 patched/known.list" ;;
        FUSE_ENABLE) _SC_HELP="温度保险丝总开关（默认开）。真实温度越界自动撤销欺骗、回原厂保护" ;;
        FUSE_COOLDOWN) _SC_HELP="保险丝触发后冷却时长（秒）。期间拒绝重新去温控" ;;
        BOOT_FAIL_LIMIT) _SC_HELP="连续几次开机没走完就自动进安全模式（默认 3）。宁可少一次去温控，也不卡开机" ;;
        FUSE_TEMP_BATT) _SC_HELP="电池路保险丝阈值（毫摄氏度，0=关该路）。默认 45000=45°C" ;;
        FUSE_TEMP_SOC) _SC_HELP="SoC 路保险丝阈值（毫摄氏度，0=关该路）。默认 80000=80°C" ;;
        FUSE_TEMP_SKIN) _SC_HELP="外壳路保险丝阈值（毫摄氏度，0=关该路）。默认 46000=46°C" ;;
        AUTO_GAME_PRESET) _SC_HELP="按前台应用自动切档。命中 game_list 的游戏自动应用 game 档，退出约 90s 后恢复" ;;
        SPOOF_BATT) _SC_HELP="电池温度是否欺骗。0=保留充电过温保护（更安全），1=连电池一起欺骗" ;;
        SOC_T)       _SC_HELP="SoC/主板/射频类温感欺骗目标值（毫摄氏度）。默认 29500=29.5°C" ;;
        SKIN_T)      _SC_HELP="外壳/皮肤类温感欺骗目标值（毫摄氏度）。设太高会触发厂商降亮度" ;;
        CAM_T)       _SC_HELP="相机类温感欺骗目标值（毫摄氏度）" ;;
        BATT_T)      _SC_HELP="电池/USB 类温感欺骗目标值（毫摄氏度）。默认不欺骗（SPOOF_BATT=0）" ;;
        SHELL_PROC_T) _SC_HELP="/proc/shell-temp 写入值（毫摄氏度）" ;;
        BLACKLIST)   _SC_HELP="不参与欺骗的温感通配符列表（空格分隔）。显示/环境光类默认排除，防亮度异常" ;;
        *) return 1 ;;
    esac
    return 0
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
