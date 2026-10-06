#!/system/bin/sh
# Action 按钮：无参数 = 启动 WebUI 并打开浏览器
#   手动：sh action.sh on|off|dynamic|status|temp|conflicts|bsafe|diag|diagpack|preset|touch|rr_restore|webui
#   v2.11.0：preset        列出全部场景预设档（含当前匹配度）
#            preset daily 应用某个预设（只接管该档声明过的键）
#   v2.12.0：panic         进入安全模式：撤销一切改写 + MODE=off（自救用）
#            fuse          查看温度保险丝状态与触发记录
#   v2.13.0：doctor        一键体检：环境/生效/风险，8 节纯文本报告（可直接复制反馈）
MODDIR=${0%/*}
# 兜底：以相对路径调用（如 cd 进模块目录后 sh action.sh）时 ${0%/*} 拿不到目录
[ -d "$MODDIR/common" ] || MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
export MODDIR
export TR_SIDE_EFFECTS=1
. "$MODDIR/common/functions.sh"

PORT=37654
URL="http://127.0.0.1:${PORT}/"

print_msg() {
    if command -v ui_print >/dev/null 2>&1; then ui_print "$1"; else echo "$1"; fi
}

set_mode() {
    # 用 | 作 sed 定界符（值来自 case 白名单，不含 / & |，此处仅统一风格）
    sed -i "s|^MODE=.*|MODE=$1|" "$MODE_CONF" 2>/dev/null
    # v2.12.0：用户主动改回 on/dynamic 视为确认设备正常 → 退出安全模式标记
    [ "$1" != "off" ] && safe_mode_exit
    print_msg "MODE 已切换为 $1（5 秒内自动生效）"
}

start_webui() {
    WEBUI_PORT="$PORT" "$MODDIR/webui_server.sh" || {
        print_msg "无法启动 WebUI：未找到支持 httpd 的 busybox"
        return 1
    }
    if command -v am >/dev/null 2>&1; then
        am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
        print_msg "已打开 WebUI：$URL"
    else
        print_msg "请在浏览器打开：$URL"
    fi
    return 0
}

# ═══ v2.10.0 诊断包：一键收集运行状态与日志，打包供下载/分享 ═══════════
# 设计要点：
#   · 纯只读收集 —— 不写任何模块状态、不改配置（只在 /data/local/tmp 与目标目录写产物）
#   · 分文件而非一坨：便于对方按需只看某一节，也便于 grep
#   · 有 manifest：先看 00-README 就知道包里有什么、各自多大
#   · tar 不可用时降级为「单个 .txt」—— 内容一字不少，只是没压缩、没分文件
#   · 日志默认只收尾部 DIAG_LOG_LINES 行（默认 500）：完整日志可能几 MB，
#     而诊断通常只需要最近的上下文；需要全量时设 DIAG_LOG_LINES=0
DIAG_LOG_LINES="${DIAG_LOG_LINES:-500}"
build_diagpack() {
    _dl="${DOWNLOAD_DIR:-/sdcard/Download}"
    _ts=$(date '+%Y%m%d_%H%M%S')
    _wk="/data/local/tmp/gt8_diag_$$"
    mkdir -p "$_wk" 2>/dev/null || { print_msg "无法创建临时目录 $_wk"; return 1; }
    load_conf

    _S="$_wk/gt8_thermal_diag_$_ts"
    mkdir -p "$_S" 2>/dev/null || { print_msg "无法创建 $_S"; return 1; }

    # ── 01 设备信息 ──
    {
        echo "=== 设备 / 系统 ==="
        echo "生成时间   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "机型       : $(getprop ro.product.model 2>/dev/null)"
        echo "设备代号   : $(getprop ro.product.device 2>/dev/null) / $(getprop ro.product.name 2>/dev/null)"
        echo "品牌       : $(getprop ro.product.brand 2>/dev/null)"
        echo "ROM        : $(getprop ro.build.display.id 2>/dev/null)"
        echo "Android    : $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
        echo "安全补丁   : $(getprop ro.build.version.security_patch 2>/dev/null)"
        echo "内核       : $(uname -a 2>/dev/null)"
        echo "ABI        : $(getprop ro.product.cpu.abi 2>/dev/null)"
        # v2.10.1：SukiSU/KernelSU 各分支用的属性名不同，逐个探（原来只探 2 个，
        # 真机上两个都为空 → 诊断包里这一行是空白，等于没有这个信息）。
        _ksu=""
        for _kp in ro.sukisu.version ro.sukisu.version.name ro.kernelsu.version \
                   persist.ksu.version persist.sys.ksu.version \
                   ro.ksu.version persist.sukisu.version; do
            _kv=""; _kv=$(getprop "$_kp" 2>/dev/null)
            [ -n "$_kv" ] && { _ksu="$_kv ($_kp)"; break; }
        done
        if [ -z "$_ksu" ] && [ -f /data/adb/ksu/version ]; then
            _kv=""; read -r _kv < /data/adb/ksu/version 2>/dev/null
            [ -n "$_kv" ] && _ksu="$_kv (/data/adb/ksu/version)"
        fi
        [ -z "$_ksu" ] && _ksu="(未取到，可忽略)"
        echo "SukiSU/KSU : $_ksu"
        echo "内核 SU 目录: $(ls -d /data/adb/ksu /data/adb/sukisu /data/adb/ap 2>/dev/null | tr '\n' ' ')"
        echo
        echo "=== 模块版本 ==="
        cat "$MODDIR/module.prop" 2>/dev/null
        echo
        echo "=== 模块目录结构（前 40 项）==="
        ls -la "$MODDIR" 2>/dev/null | head -n 40
    } > "$_S/01-device.txt" 2>&1

    # ── 02 配置全文（排查「用户到底配了什么」必须）──
    {
        echo "########## mode.conf ##########"
        cat "$MODE_CONF" 2>/dev/null | grep -v '^[[:space:]]*$'
        echo
        echo "########## spoof.conf ##########"
        cat "$SPOOF_CONF" 2>/dev/null | grep -v '^[[:space:]]*$'
        echo
        echo "########## game_list.conf（去注释）##########"
        grep -v '^[[:space:]]*#' "$GAME_LIST" 2>/dev/null | grep -v '^[[:space:]]*$'
        echo "########## protect_list.conf（去注释）##########"
        grep -v '^[[:space:]]*#' "$PROTECT_LIST" 2>/dev/null | grep -v '^[[:space:]]*$'
    } > "$_S/02-config.txt" 2>&1

    # ── 03 运行状态 ──
    {
        echo "=== 运行状态 ==="
        echo "state 文件 : $(cat "$STATE_FILE" 2>/dev/null)  ($STATE_FILE)"
        echo "解析后模式 : MODE=$MODE  LOG_LEVEL=$LOG_LEVEL(=$LOG_LEVEL_NUM)  UNLOCK_FREQ=$UNLOCK_FREQ  UNLOCK_GPU=$UNLOCK_GPU  UNLOCK_CDEV=$UNLOCK_CDEV"
        echo "充电中     : $(get_charging)"
        echo "emul_temp  : $(spoof_supported && echo 支持 || echo 不支持)"
        echo "欺骗记账   : $(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ') 条  ($SPOOF_LIST)"
        echo "已挂载配置 : $(wc -l < "$MOUNT_LIST" 2>/dev/null | tr -d ' ') 项"
        echo
        echo "=== 持久化文件（大小 / 修改时间）==="
        ls -l "$PERSIST_DIR" 2>/dev/null
        echo
        echo "=== 挂载记账（mounts.list）==="
        cat "$MOUNT_LIST" 2>/dev/null
        echo
        echo "=== sysfs 备份（还原用，前 60 行）==="
        head -n 60 "$SYSFS_BAK" 2>/dev/null
        echo
        echo "=== GPU 频锁记账 ==="
        echo "--- gpu_lock.bak ---"
        cat "$LOCK_BAK" 2>/dev/null
        echo "--- gpu_locked.list ---"
        cat "$LOCKED_NODES" 2>/dev/null
    } > "$_S/03-runtime.txt" 2>&1

    # ── 04 温感与冷却设备（核心诊断对象）──
    {
        echo "=== 温感（thermal_zone）==="
        dump_temp
        echo
        echo "=== 冷却设备（cooling_device）==="
        dump_cdev
        echo
        echo "=== 关键 sysfs 当前值 ==="
        for _f in /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq \
                  /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq \
                  /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq \
                  /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq \
                  /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq \
                  /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq \
                  /sys/class/kgsl/kgsl-3d0/devfreq/max_freq \
                  /sys/class/kgsl/kgsl-3d0/max_gpu_clk \
                  /sys/class/kgsl/kgsl-3d0/max_clock_mhz; do
            [ -e "$_f" ] && printf '  %-64s = %s\n' "$_f" "$(cat "$_f" 2>/dev/null)"
        done
        # v2.11.1：GPU 甜点值（GPU_MAX_CLK）单位是 Hz，而 max_gpu_clk / max_clock_mhz
        # 是 HORAE 继承的 legacy 接口；SM8750 上真正压制频率的多半是 devfreq 的
        # max_freq（上面已并列输出）。改甜点值后，请以上面 devfreq/cur_freq 为准
        # 确认哪个节点真的生效 —— legacy 两个值可能没变化，不代表没生效。
        echo
        echo "=== emul_temp 探针（记账前 5 条）==="
        # v2.10.1：不再单列 thermal_zone0/emul_temp 的**回读值** —— 真机实测该内核
        # 回读为空（这正是模块坚持用记账 spoof.list 判定欺骗、而非回读的根本原因）。
        # 回读值没有诊断价值，改为「记账目标值 + 回读」并排，一眼能看出这个现象。
        _pi=0
        while IFS='|' read -r _pd _pv; do
            [ -n "$_pd" ] || continue
            _pi=$((_pi + 1)); [ "$_pi" -gt 5 ] && break
            _pty=""; read -r _pty < "$_pd/type" 2>/dev/null
            _prb=""; read -r _prb < "$_pd/emul_temp" 2>/dev/null
            printf '  %-24s 记账值=%-8s 回读=[%s]\n' "${_pty:-${_pd##*/}}" "$_pv" "${_prb:-空}"
        done < "$SPOOF_LIST" 2>/dev/null
        [ "$_pi" = "0" ] && echo "  （记账为空：当前未处于欺骗状态）"
        echo "  说明：回读为空/0 是部分厂商内核的已知现象（写入实际生效但回读不反映），"
        echo "        因此本模块一律以记账 spoof.list 判定欺骗状态。"
        echo
        echo "=== emul_temp 支持统计 ==="
        _e_n=0; _z_n=0
        for _z in /sys/class/thermal/thermal_zone*; do
            [ -e "$_z/temp" ] || continue
            _z_n=$((_z_n + 1))
            [ -e "$_z/emul_temp" ] && _e_n=$((_e_n + 1))
        done
        echo "  温感总数 $_z_n，支持 emul_temp $_e_n，不支持 $((_z_n - _e_n))"
        echo
        echo "=== CPU 频率三级对照（硬件极限 / 本模块改写前备份 / 当前）==="
        # v2.10.1 新增：这是定位「谁在改频率」最有用的一张表。
        # 真机诊断包靠它发现：备份原值里 cpu0-5 的 min_freq 已是 1785600、
        # cpu6-7 是 3072000（硬件最低仅 384000/1017600）—— 说明在我们动之前，
        # 已经**有别的东西把 CPU 下限锁高**了（锁高频是性能调度类工具的手法，
        # 不是温控限频）。只看「当前值」永远发现不了这一点。
        for _c in 0 6; do
            _dir="/sys/devices/system/cpu/cpu$_c/cpufreq"
            [ -d "$_dir" ] || continue
            _hi=""; read -r _hi < "$_dir/cpuinfo_max_freq" 2>/dev/null
            _lo=""; read -r _lo < "$_dir/cpuinfo_min_freq" 2>/dev/null
            _cmx=""; read -r _cmx < "$_dir/scaling_max_freq" 2>/dev/null
            _cmn=""; read -r _cmn < "$_dir/scaling_min_freq" 2>/dev/null
            _bmx="-"; _bmn="-"
            if [ -f "$SYSFS_BAK" ]; then
                _bmx=$(grep -m1 "^$_dir/scaling_max_freq=" "$SYSFS_BAK" 2>/dev/null)
                _bmn=$(grep -m1 "^$_dir/scaling_min_freq=" "$SYSFS_BAK" 2>/dev/null)
                _bmx=${_bmx#*=}; _bmn=${_bmn#*=}
                [ -n "$_bmx" ] || _bmx="-"
                [ -n "$_bmn" ] || _bmn="-"
            fi
            printf '  cpu%-2s 硬件[%s~%s]  备份前[%s~%s]  当前[%s~%s]\n' \
                "$_c" "${_lo:-?}" "${_hi:-?}" "$_bmn" "$_bmx" "$_cmn" "$_cmx"
        done
        echo "  读法：若「备份前 min」明显高于「硬件 min」，说明本模块介入**之前**"
        echo "        就已有其它工具抬高了下限（锁高频），排查方向应指向性能调度类模块。"
    } > "$_S/04-thermal.txt" 2>&1

    # ── 05 冲突检测 ──
    {
        echo "=== 模块冲突自检 ==="
        echo "扫描目录: ${MODULES_DIR:-/data/adb/modules}"
        echo "自身 id : ${SELF_ID:-realme-gt8-sukisu-thermal-remove}"
        echo
        SCAN_RESOURCES=1 detect_conflicts 2>/dev/null || echo "(检测库不可用)"
        echo
        echo "=== /data/adb/modules 下已装模块 ==="
        for _m in /data/adb/modules/*; do
            [ -d "$_m" ] || continue
            _id="${_m##*/}"
            _v=$(grep -m1 '^version=' "$_m/module.prop" 2>/dev/null | cut -d= -f2-)
            [ -e "$_m/disable" ] && _st="(已禁用)" || _st=""
            printf '  %-40s %s %s\n' "$_id" "$_v" "$_st"
        done
    } > "$_S/05-conflicts.txt" 2>&1

    # ── 06 日志 ──
    if [ -s "$LOG_FILE" ]; then
        if [ "$DIAG_LOG_LINES" -gt 0 ] 2>/dev/null; then
            {
                echo "=== 日志尾部 $DIAG_LOG_LINES 行（全文 $(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ') 行）==="
                echo "=== 级别分布（本段）==="
                tail -n "$DIAG_LOG_LINES" "$LOG_FILE" 2>/dev/null | grep -o '\[DBG\]\|\[INF\]\|\[WRN\]\|\[ERR\]' | sort | uniq -c
                echo
                tail -n "$DIAG_LOG_LINES" "$LOG_FILE" 2>/dev/null
            } > "$_S/06-log.txt" 2>&1
        else
            cp "$LOG_FILE" "$_S/06-log.txt" 2>/dev/null
        fi
    else
        echo "(日志为空或不存在: $LOG_FILE)" > "$_S/06-log.txt"
    fi

    # ── 07 保险丝状态与三路真实温度（v2.13.3）──
    # 之前诊断包没有这一节，导致「保险丝采样是否在跑 / 真实温度离阈值多远」
    # 完全不可见（fuse.log 只在触发时才存在）。本节补上：纯只读 + 短暂采真值。
    {
        fuse_report
    } > "$_S/07-fuse.txt" 2>&1

    # ── 00 README + manifest ──
    {
        echo "GT8 ThermalRemove · 诊断包"
        echo "=========================="
        echo "生成时间 : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "模块版本 : $(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-) (versionCode $(grep -m1 '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-))"
        echo "机型     : $(getprop ro.product.model 2>/dev/null) / Android $(getprop ro.build.version.release 2>/dev/null)"
        echo
        echo "包含内容："
        echo "  01-device.txt    设备/系统/模块版本信息"
        echo "  02-config.txt    mode.conf 与 spoof.conf 全文"
        echo "  03-runtime.txt   运行状态、记账文件、挂载与备份"
        echo "  04-thermal.txt   全部温感读数 + 冷却设备 + 关键 sysfs"
        echo "  05-conflicts.txt 模块冲突自检 + 已装模块清单"
        echo "  06-log.txt       运行日志（默认尾部 $DIAG_LOG_LINES 行）"
        echo "  07-fuse.txt      温度保险丝状态 + 三路真实温度 + 触发记录"
        echo
        echo "说明：本包仅供排查使用，不含任何账号/隐私数据。"
        echo "      如需完整日志，可在 mode.conf 设 DIAG_LOG_LINES=0 后重新导出。"
        echo
        echo "--- 各文件行数 ---"
        wc -l "$_S"/* 2>/dev/null
    } > "$_S/00-README.txt" 2>&1

    # ── 打包：优先 tar.gz，不可用则降级为单文件 txt ──
    mkdir -p "$_dl" 2>/dev/null
    if [ ! -d "$_dl" ]; then
        print_msg "目标目录不可写：$_dl（可用 DOWNLOAD_DIR=... 指定其它目录）"
        rm -rf "$_wk"; return 1
    fi

    _out=""
    if command -v tar >/dev/null 2>&1 && \
       (cd "$_wk" && tar czf "$_dl/gt8_thermal_diag_$_ts.tar.gz" "gt8_thermal_diag_$_ts" 2>/dev/null) && \
       [ -s "$_dl/gt8_thermal_diag_$_ts.tar.gz" ]; then
        _out="$_dl/gt8_thermal_diag_$_ts.tar.gz"
    else
        # 降级：把各节拼成单个文本文件（内容一字不少，只是没分文件）
        _out="$_dl/gt8_thermal_diag_$_ts.txt"
        : > "$_out" 2>/dev/null
        for _f in "$_S"/00-README.txt "$_S"/01-device.txt "$_S"/02-config.txt \
                  "$_S"/03-runtime.txt "$_S"/04-thermal.txt "$_S"/05-conflicts.txt \
                  "$_S"/06-log.txt "$_S"/07-fuse.txt; do
            [ -f "$_f" ] || continue
            {
                echo
                echo "════════════════════════════════════════════════════════"
                echo "# ${_f##*/}"
                echo "════════════════════════════════════════════════════════"
                cat "$_f"
            } >> "$_out" 2>/dev/null
        done
    fi
    rm -rf "$_wk" 2>/dev/null

    if [ -n "$_out" ] && [ -s "$_out" ]; then
        print_msg "诊断包已导出：$_out ($(wc -c < "$_out" 2>/dev/null | tr -d ' ') B)"
        echo "$_out"      # 供 api.sh / 脚本解析
        return 0
    fi
    print_msg "诊断包导出失败（$_dl 不可写？）"
    return 1
}

case "$1" in
    on)     set_mode always ;;
    off)    set_mode off ;;
    dynamic) set_mode dynamic ;;
    # v2.12.0：安全模式 —— 撤销一切改写并把 MODE 置 off（一条命令回到原厂状态）。
    # 用户误开 always 后机身发烫、或某次改动后系统异常时用这个自救。
    panic)
        load_conf
        panic_to_safe
        print_msg "已进入安全模式：温控完全恢复原厂（MODE=off）。"
        print_msg "机身冷却/确认稳定后重新启用：sh action.sh dynamic（或 on）"
        echo "安全模式：MODE=off，欺骗已撤销，sysfs 已还原"
        ;;
    # v2.12.0：温度保险丝状态
    # v2.13.3：统一走 fuse_report（含三路真实温度 + 触发记录 + 安全模式）
    fuse)
        load_conf
        fuse_report
        ;;
    # v2.13.0：一键体检 —— 环境是否支持 / 是否生效 / 有哪些风险，一条命令出报告
    doctor)
        load_conf
        doctor_report
        ;;
    temp)   dump_temp ;;
    # v2.10.0：一键导出诊断包（设备信息 + 配置 + 运行状态 + 温感 + 冲突 + 日志）
    diagpack)
        build_diagpack
        ;;
    webui)  start_webui ;;
    # ── v2.11.0：场景预设档（引擎与 WebUI 共用 common/presets.sh）─────────
    # 不带参数 = 列出全部档位与当前匹配度；带参数 = 应用该档。
    preset)
        if [ ! -f "$MODDIR/common/presets.sh" ]; then
            print_msg "预设引擎不存在：$MODDIR/common/presets.sh"
            exit 1
        fi
        . "$MODDIR/common/presets.sh"
        if [ -z "$2" ]; then
            echo "=== 场景预设档 ==="
            for _psid in $(preset_ids); do
                preset_meta_into "$_psid"
                preset_match_into "$_psid"
                _mark=" "
                [ "$_PMT_T" -gt 0 ] && [ "$_PMT_M" = "$_PMT_T" ] && _mark="★"
                printf '  %s %-7s %s %s\n' "$_mark" "$_psid" "$_PM_ICON" "$_PM_NAME"
                printf '        %s/%s 项匹配 · 风险=%-8s · %s\n' \
                    "$_PMT_M" "$_PMT_T" "$_PM_RISK" "$_PM_TAGS"
            done
            echo ""
            echo "  用法：sh $(basename "$0") preset <id>"
            echo "  预设只接管自己声明过的键；BLACKLIST / 真实温度开关等"
            echo "  个性化设置不会被改动。"
        elif preset_apply "$2" > /dev/null 2>&1; then
            preset_meta_into "$2"
            print_msg "已应用预设「$_PM_NAME」（$2）：5 秒内生效"
        else
            print_msg "应用失败：未知或非法的预设 id「$2」"
            print_msg "执行 sh $(basename "$0") preset 可列出全部可用预设"
            exit 1
        fi
        ;;
    # v2.17.5 / U5：预设导出 —— 打印某档完整 .conf 内容，可直接复制分享
    preset-export)
        [ -f "$MODDIR/common/presets.sh" ] || { print_msg "预设引擎不存在"; exit 1; }
        . "$MODDIR/common/presets.sh"
        if [ -z "$2" ]; then
            echo "用法：sh $(basename "$0") preset-export <id>"
            echo "可用预设：$(preset_ids | tr '\n' ' ')"
            exit 1
        fi
        if preset_export "$2"; then
            :
        else
            print_msg "导出失败：未知或非法的预设 id「$2」"
            exit 1
        fi
        ;;
    # v2.17.5 / U5：预设导入 —— 从 stdin 读 K=V 文本，校验后存为新档
    preset-import)
        [ -f "$MODDIR/common/presets.sh" ] || { print_msg "预设引擎不存在"; exit 1; }
        . "$MODDIR/common/presets.sh"
        if [ -z "$2" ]; then
            echo "用法：cat recipe.txt | sh $(basename "$0") preset-import <新档id>"
            echo "  · id 只允许 [a-z0-9_-]，不能是内置档（stock/daily/game/cool/debug）"
            echo "  · 内容为 K=V 文本；键过白名单、值过值域校验，任一行非法整体拒绝"
            exit 1
        fi
        if preset_import "$2"; then
            preset_meta_into "$2"
            print_msg "已导入预设「$_PM_NAME」（$2），可在 WebUI / preset 列表看到"
        else
            print_msg "导入失败：内容含非法键/值，或 id 非法/为内置档"
            exit 1
        fi
        ;;
    # 亮度安全预设：关掉一切可能影响亮度/显示的手段，并还原已被动过的冷却节点
    bsafe)
        sed -i 's/^UNLOCK_CDEV=.*/UNLOCK_CDEV=0/'     "$MODE_CONF" 2>/dev/null
        sed -i 's/^DISPLAY_PROTECT=.*/DISPLAY_PROTECT=1/' "$MODE_CONF" 2>/dev/null
        for _k in OPPO_SHELL_TEMP OPPO_GAUGE HORAE_TESTMODE DISABLE_ORMS STOP_SERVICES PATCH_EXTRA; do
            sed -i "s/^$_k=.*/$_k=0/" "$MODE_CONF" 2>/dev/null
        done
        sed -i 's/^SKIN_T=.*/SKIN_T=29500/' "$SPOOF_CONF" 2>/dev/null
        load_conf
        rm -f "$PERSIST_DIR/.cdev_restored"
        restore_cdev_once
        print_msg "已切到亮度安全预设：cooling_device 已还原、全部风险项关闭、皮肤温度 29.5°C"
        print_msg "观察 10 秒；仍异常请执行: sh $(basename "$0") off"
        ;;
    # 亮度/温控诊断：把冷却设备、温感、亮度属性一次性打出来
    diag)
        load_conf
        echo "=== 冷却设备 cooling_device ==="
        dump_cdev
        echo "=== 温感 thermal_zone ==="
        dump_temp
        echo "=== UNLOCK_CDEV 开关 ==="
        echo "  UNLOCK_CDEV=$UNLOCK_CDEV  DISPLAY_PROTECT=$DISPLAY_PROTECT  SKIN_T=$SKIN_T"
        echo "=== 亮度/显示相关属性 ==="
        # v2.8.6：后 4 个是第三方模块常写的显示/亮度开关（评审「慕容 ColorOS
        # 附加模块」时收录），本机不写它们，但用户刷了别的模块后会被注入
        for _p in persist.sys.oplus.screen.brightness persist.sys.screen.brightness \
                  sys.display.temperature persist.sys.thermal.brightness \
                  persist.sys.environment.temp persist.sys.oplus.thermal.level \
                  vendor.display.brightness \
                  ro.display.brightness.brightness.mode \
                  persist.oplus.display.pixelworks \
                  persist.oplus.display.vrr \
                  persist.sys.oplus.anim_level; do
            _v=$(getprop "$_p" 2>/dev/null)
            [ -n "$_v" ] && echo "  $_p=$_v"
        done
        echo "  screen_brightness(settings) = $(settings get system screen_brightness 2>/dev/null)"
        echo "=== dumpsys display 亮度行 ==="
        dumpsys display 2>/dev/null | grep -iE 'brightness|BrightnessLevel' | head -n 12
        # v2.8.9 修正：v2.8.6 这里用 [ -s "$_f" ]（大小>0）判定「被覆盖」，
        # 但原厂这些文件本来就是非空的（refresh_rate_config.xml 原厂就有近两千条），
        # 于是每次 diag 必然报 4 个 ⚠ —— 100% 假阳性。
        # v2.8.10 补正判据边界：挂载点除了「等于该文件」，还要包含「是该文件的祖先目录」
        # —— 第三方模块 bind 整个 /my_product/etc 目录时挂载点是目录，v2.8.9 的
        # 完全相等匹配会漏检（而漏检比误报更糟：会让人直接排除掉真正的嫌疑源）。
        #
        # 已知的能力边界（查不出来，别把这一段的否定结论当定论）：
        #   · Magisk/KernelSU 的 magic mount（挂载类型是 overlay，不是 bind）
        #   · 第三方模块对分区文件 sed -i 原地改写
        # 这两种要靠下面的「/data/system 运行时副本」段与 rr_restore 去兜。
        echo "=== 第三方显示配置覆盖（bind mount 判定）==="
        _hit=0
        for _f in /my_product/etc/refresh_rate_config.xml \
                  /my_product/etc/oplus_vrr_config.json \
                  /my_product/vendor/etc/display_brightness_config_P_3.xml \
                  /my_product/vendor/etc/display_brightness_app_list.xml; do
            [ -f "$_f" ] || continue
            # 一次 awk 给出「层级|源路径」：
            #   index(m,$2)==1            挂载点 = 该文件本身，或为其祖先目录
            #   substr(m,length($2)+1,1)  边界必须是 '/'，避免 /my_product2 之类子串误配
            #   $1 ~ /^\/data\//          只认源在 /data/ 下的挂载 —— 模块目录都在
            #                             /data/adb/modules；不加这条会把 /my_product
            #                             分区挂载本身误判成「被第三方覆盖」。
            # 字段精确比较（不用 grep：路径里的 '.' 会被当正则）。
            _res=$(awk -v m="$_f" \
                'index(m,$2)==1 && (length($2)==length(m) || substr(m,length($2)+1,1)=="/") \
                 && $1 ~ /^\/data\// {print ($2==m ? "F" : "D") "|" $1; exit}' \
                /proc/mounts 2>/dev/null)
            [ -n "$_res" ] || continue
            _lv=${_res%%|*}
            _src=${_res#*|}
            [ "$_lv" = "F" ] && _lv="文件级" || _lv="目录级"
            echo "  ⚠ $_f 被 bind mount 覆盖（$_lv，$(wc -c < "$_f" 2>/dev/null | tr -d ' ') B）"
            echo "      源: $_src"
            _hit=1
        done
        if [ -e /vendor/etc/perf/perfboostsconfig.xml ] && \
           [ ! -s /vendor/etc/perf/perfboostsconfig.xml ]; then
            echo "  ⚠ /vendor/etc/perf/perfboostsconfig.xml 为空 → 高通 perf boost 已被关闭"
            _hit=1
        fi
        [ "$_hit" = "0" ] && {
            echo "  ✓ 未发现 bind mount 形式的覆盖"
            echo "    （只代表没查到 bind mount：overlay 覆盖与对分区文件的原地改写查不出来，"
            echo "      仍需结合下方「/data/system 运行时副本」段判断）"
        }
        # v2.8.9：VRR 配置里藏着亮度字段 —— 解析「ColorOS 显示优化 2.2」时发现。
        # hw_nit_limit 是**硬件层 nit 上限**，非 0 就是「亮度怎么拉都上不去」的直接成因，
        # 而我们此前的排查只覆盖 sysfs 节点与属性，完全看不到这一层。
        # v2.8.11 **改判据**：不再用「非 0 = 被钳制」——
        #   GT8 实测原厂 hw_nit_limit = 50，而同一份 dumpsys 里
        #   mMinimumBrightnessCurve = [(0.0,0.0),(2000.0,50.0),(4000.0,90.0)]，
        #   同样是 50/90 —— 说明它是**亮度曲线百分比**而不是 nits，语义根本不是「上限」。
        #   按绝对值报警等于天天误报（v2.8.10 在实机上确实一直在报）。
        #   唯一可靠的判据是**与安装期记录的原厂基线比对**：变了才说明被第三方改写。
        # 用 sed 逐键提取，不依赖 jq（设备通常没有）；单行紧凑 JSON 也能吃，不挑缩进。
        echo "=== 显示配置内的亮度限制字段（v2.8.9）==="
        _vrr=/my_product/etc/oplus_vrr_config.json
        if [ -s "$_vrr" ]; then
            _bf=$(sed -n 's/.*"hw_nit_limit"[[:space:]]*:[[:space:]]*["]*\([0-9.-]*\).*/\1/p' "$_vrr" 2>/dev/null | head -n 1)
            _bp=$(sed -n 's/.*"hw_nit_limit_pwm"[[:space:]]*:[[:space:]]*["]*\([0-9.-]*\).*/\1/p' "$_vrr" 2>/dev/null | head -n 1)
            _ab=$(sed -n 's/.*"avt_backlight"[[:space:]]*:[[:space:]]*["]*\([0-9.-]*\).*/\1/p' "$_vrr" 2>/dev/null | head -n 1)
            _sb=$(sed -n 's/.*"sa_backlight"[[:space:]]*:[[:space:]]*["]*\([a-z]*\).*/\1/p' "$_vrr" 2>/dev/null | head -n 1)
            _bbs=$(vrr_baseline_get hw_nit_limit)
            _bpb=$(vrr_baseline_get hw_nit_limit_pwm)
            printf '  %s\n' "$_vrr"
            printf '    hw_nit_limit=%s  hw_nit_limit_pwm=%s  avt_backlight=%s  sa_backlight=%s\n' \
                "${_bf:-未设置}" "${_bp:-未设置}" "${_ab:-未设置}" "${_sb:-未设置}"
            # v2.8.11：判据从「绝对值非 0」改为「与安装期原厂基线不同」。
            # 缺基线时**绝不报警** —— 缺基准就下结论等于新一轮假阳性。
            if [ -z "$_bbs" ] && [ -z "$_bpb" ]; then
                echo "    ⓘ 无安装期基线（v2.8.11 起记录）：当前值仅供参考，不做判定"
                echo "      重装一次本模块即可建立基线并获得对照"
            else
                _same=1
                if [ -n "$_bbs" ] && [ -n "$_bf" ] && [ "$_bf" != "$_bbs" ]; then
                    echo "    ⚠ hw_nit_limit 与基线不同（原厂 $_bbs → 当前 $_bf）：被第三方改写"
                    _same=0
                fi
                if [ -n "$_bpb" ] && [ -n "$_bp" ] && [ "$_bp" != "$_bpb" ]; then
                    echo "    ⚠ hw_nit_limit_pwm 与基线不同（原厂 $_bpb → 当前 $_bp）：被第三方改写"
                    _same=0
                fi
                [ "$_same" = "1" ] && echo "    ⓘ 已对照的字段均与安装期基线一致 → 未被改写"
            fi
        else
            echo "  $_vrr 不存在或为空（跳过）"
        fi
        # v2.8.7：/data/system 运行时副本 —— 优先级高于分区里的原始文件。
        # 它被改坏且对方无卸载脚本时无法还原，是刷新率/亮度异常的常见死角。
        echo "=== /data/system 运行时副本（v2.8.7）==="
        _rb="$PERSIST_DIR/runtime_backup"
        _rn=0
        for _kn in refresh_rate_config.xml sys_resolution_switch_config.xml \
                   oplus_vrr_config.json; do
            _cur="/data/system/$_kn"
            [ -f "$_cur" ] || continue
            _rn=$((_rn + 1))
            printf '  %s (%s B)\n' "$_kn" "$(wc -c < "$_cur" 2>/dev/null | tr -d ' ')"
            if [ -f "$_rb/$_kn" ]; then
                # 先比字节数（便宜且必定可用），不同即判定被改过；
                # 大小相同时才动用 cmp —— 万一设备缺 cmp，也不会反向误报
                if [ "$(wc -c < "$_cur" 2>/dev/null)" != \
                     "$(wc -c < "$_rb/$_kn" 2>/dev/null)" ] || \
                   { command -v cmp >/dev/null 2>&1 && \
                     ! cmp -s "$_cur" "$_rb/$_kn" 2>/dev/null; }; then
                    echo "      ⚠ 与首次快照不一致 → 被本模块之外的东西改过（sh $0 rr_restore 可还原）"
                else
                    echo "      与首次快照一致"
                fi
            else
                echo "      - 无快照（RUNTIME_SNAPSHOT=0 或安装时该文件不存在）"
            fi
        done
        [ "$_rn" = "0" ] && echo "  ✓ /data/system 下无上述运行时副本"
        echo "  备份目录: $_rb"
        # v2.8.7：已知配置核对结果（安装期生成，含此前遗漏的 refresh_rate_config /
        # sys_resolution_switch_config —— 刻意只登记不改写，见 customize.sh 注释）
        if [ -s "$MODDIR/patched/known.list" ]; then
            echo "=== 已知配置文件核对（安装期扫描）==="
            echo "  已改写: $(grep -c '^patched|' "$MODDIR/patched/known.list" 2>/dev/null)"
            echo "  发现未改写（本模块有意不动）:"
            grep '^seen|' "$MODDIR/patched/known.list" 2>/dev/null | \
                cut -d'|' -f2 | sed 's/^/    /'
        fi
        ;;
    # v2.8.7：把 /data/system 的运行时副本还原成首次安装时的快照。
    # 用于排查「别的模块 sed -i 改坏显示配置、又没有卸载脚本」这类无法回退的场景。
    # 只还原本模块快照过的文件；没有快照就明确告知，不做任何猜测性写入。
    rr_restore)
        _rb="$PERSIST_DIR/runtime_backup"
        if [ ! -d "$_rb" ]; then
            print_msg "没有快照目录 $_rb —— 安装时 RUNTIME_SNAPSHOT=0，或当时文件不存在"
            exit 1
        fi
        _n=0
        for _f in "$_rb"/*; do
            [ -f "$_f" ] || continue
            _kn="${_f##*/}"
            [ -f "/data/system/$_kn" ] || continue
            cp "$_f" "/data/system/$_kn" 2>/dev/null && {
                echo "  已还原 /data/system/$_kn ← $_f"
                _n=$((_n + 1))
            }
        done
        [ "$_n" = "0" ] && print_msg "快照目录为空或目标文件当前不存在，未做任何改动"
        [ "$_n" -gt 0 ] && print_msg "已还原 $_n 个运行时副本，重启后生效"
        ;;
    # v2.8.8：输入链路优先级体检。验证 TOUCH_THREAD_BOOST 是否真的生效 ——
    # 三个线程的 nice 应从 0 变成 TOUCH_THREAD_NICE（默认 -19）。
    #   未生效先查：TOUCH_THREAD_BOOST=1？当前是不是 off / 充电中（这两个状态会还原）
    touch)
        load_conf
        echo "=== 输入链路优先级 ==="
        echo "TOUCH_BOOST        : $TOUCH_BOOST"
        echo "TOUCH_THREAD_BOOST : $TOUCH_THREAD_BOOST  nice目标=$TOUCH_THREAD_NICE"
        echo "当前状态           : $(cat "$STATE_FILE" 2>/dev/null)（off/充电时会还原）"
        touch_status
        ;;
    status)
        load_conf
        echo "MODE           : $MODE"
        echo "GAME_PROTECT   : $GAME_PROTECT"
        echo "STOP_SERVICES  : $STOP_SERVICES"
        echo "UNLOCK_FREQ    : $UNLOCK_FREQ"
        echo "PATCH_THERMAL  : $PATCH_THERMAL"
        echo "PATCH_EXTRA    : $PATCH_EXTRA"
        echo "OPPO_SHELL_TEMP: $OPPO_SHELL_TEMP"
        echo "OPPO_GAUGE     : $OPPO_GAUGE"
        echo "HORAE_TESTMODE : $HORAE_TESTMODE"
        echo "DISABLE_ORMS   : $DISABLE_ORMS"
        echo "TOUCH_BOOST    : $TOUCH_BOOST"
        echo "TOUCH_THREAD_BOOST: $TOUCH_THREAD_BOOST (nice=$TOUCH_THREAD_NICE)"
        echo "REPLACE_ENCRYPTED: $REPLACE_ENCRYPTED"
        echo "欺骗温度       : soc=$SOC_T skin=$SKIN_T cam=$CAM_T batt=$BATT_T shell_proc=$SHELL_PROC_T"
        echo "黑名单         : $BLACKLIST"
        echo "emul_temp      : $(spoof_supported && echo 支持 || echo 不支持)"
        echo "当前状态       : $(cat "$STATE_FILE" 2>/dev/null)"
        echo "充电中         : $(get_charging)"
        echo "前台应用       : $(get_focus_app)"
        echo "已挂载配置     : $(wc -l < "$MOUNT_LIST" 2>/dev/null || echo 0) 项"
        echo "冲突模块       : $(detect_conflicts 2>/dev/null | grep -c .) 个（sh $0 conflicts 查看详情）"
        echo "温度保险丝     : $([ "$FUSE_ENABLE" = "1" ] && echo "开启（累计触发 $(fuse_trips) 次）" || echo 关闭)（sh $0 fuse 查看详情）"
        safe_mode_active && echo "安全模式       : 是 —— 温控已交还原厂，欺骗不会应用（sh $0 dynamic 退出）"
        echo "日志           : $LOG_FILE"
        ;;
    # v2.8：模块冲突自检 —— 温控类模块会争抢同一批资源，装多个只会互相覆盖
    # v2.8.6：手动执行时强制开启 Tier C（按资源占用扫描），不管 mode.conf 里是 0 还是 1
    conflicts)
        load_conf
        SCAN_RESOURCES=1
        export SCAN_RESOURCES
        echo "=== 模块冲突自检 ==="
        echo "扫描目录: ${MODULES_DIR:-/data/adb/modules}"
        echo "自身 id : ${SELF_ID:-realme-gt8-sukisu-thermal-remove}"
        echo "资源扫描: 开启（Tier C，会读第三方模块的 *.sh / *.prop / *.rc）"
        _c=$(detect_conflicts 2>/dev/null)
        if [ -z "$_c" ]; then
            echo "  ✔ 未检测到其他温控模块"
        else
            print_conflicts "  "
            echo ""
            echo "  装多个温控模块不会叠加效果，只会互相覆盖（最后执行者获胜），"
            echo "  表现为温控行为随机、亮度异常等难以复现的问题。建议只保留一个。"
        fi
        ;;
    *)
        start_webui || {
            load_conf
            echo "MODE=$MODE 状态=$(cat "$STATE_FILE" 2>/dev/null)"
        }
        ;;
esac
exit 0
