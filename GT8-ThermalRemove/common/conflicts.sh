#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════
#  模块冲突检测库 v1.0（v2.8 引入）
#
#  为什么需要它：温控类模块不是各管一摊，而是往同一批资源上写 ——
#    thermal_zone*/emul_temp、horae 服务、/proc/shell-temp、
#    sys_thermal*/game_thermal XML、cooling_device。
#    同时装两个时「最后执行者获胜」，表现为温控行为随机、亮度异常等。
#  本库只做「发现并告警」，不做任何阻断 —— 是否卸载由用户决定。
#
#  设计约束（务必遵守，否则会波及安装期）：
#    · 纯函数、零副作用：不建目录、不写文件、不依赖 getprop / mode.conf
#    · POSIX sh：不出现 [[ ]] / local / array 等 bash 特性
#    · 安装期（customize.sh）与运行时（service/action/api）共用同一份实现
#
#  source 前可设置：
#    MODULES_DIR     模块根目录，默认 /data/adb/modules
#    SELF_ID         自身 id，默认 realme-gt8-sukisu-thermal-remove
#    SCAN_RESOURCES  1 = 额外启用 Tier C（按资源占用扫描第三方模块的脚本/属性）
#                    默认 0 —— 有 IO 成本，只在安装期与手动 conflicts 时开启，
#                    运行时主循环（5s 一轮）务必保持关闭。
#
#  输出格式（每行一条）：id|name|version|risk|note
#    risk=high    已确认争抢同一批资源（见 match_known）
#    risk=medium  名称/ID 含温控关键词，或已知目标相反（见 match_known）
#    risk=low     Tier C 命中：脚本/属性里出现温控资源关键字，需人工确认
# ═══════════════════════════════════════════════════════════════

MODULES_DIR="${MODULES_DIR:-/data/adb/modules}"
SELF_ID="${SELF_ID:-realme-gt8-sukisu-thermal-remove}"

# ── Tier A：已确认会争抢同一批资源的模块 ────────────────────────
#   依据：模块评审-HORAE-ExtremeGT-Moka.md 第 4 节 C1~C5
match_known() {                      # $1=id  $2=name  $3=version
    case "$1" in
        thermal_horae_extreme)
            echo "$1|$2|$3|high|争抢 sys_thermal*/game_thermal XML 与 horae 服务（其 ctl.start/stop 与本机策略互斥）"
            return 0 ;;
        extreme_gt)
            echo "$1|$2|$3|high|争抢同一批 XML 配置；且其 emul_temp 欺骗在 SM8750 上并不执行"
            return 0 ;;
        manyapps_moka)
            echo "$1|$2|$3|high|8 层混淆 + eval，init.svc.horae=stopped 与本机直接对撞，行为不可审计"
            return 0 ;;
        # v2.8.6 新增：不定 high —— 它不碰 emul_temp / thermal_zone / cooling_device，
        # 不构成温控资源争抢；冲突点是「目标相反 + 显示侧副作用」。
        murongltpo)
            echo "$1|$2|$3|medium|慕容 ColorOS 附加模块：清空 QTI perfboostsconfig/perfconfigstore（关掉高通 perf boost）并全局锁 120Hz，与本模块 UNLOCK_FREQ/TOUCH_BOOST 目标相悖；其 display 配置来自 2024 年固件与其它机型，可能引发亮度/刷新率异常"
            return 0 ;;
        # v2.8.9 新增：同样不碰温控资源（定 medium），但整份替换 VRR 总配置，
        # 且 sf_framerate_ranges 上限只有 120 —— GT8 是 144Hz 面板，覆盖即降级。
        # 它与 murongltpo 覆盖**同一个文件**，两者也互斥（谁后挂载谁生效）。
        ColorOS_Display_Optimization)
            echo "$1|$2|$3|medium|ColorOS 显示优化：整份替换 /my_product/etc/oplus_vrr_config.json（version 20240910，sf_framerate_ranges 上限 120，而 GT8 为 144Hz 面板 → 覆盖即降级；sa_backlight 全亮度调光与官方「全程 DC」重复）；与「慕容 ColorOS 附加模块」覆盖同一文件，两者互斥"
            return 0 ;;
        # ═══ v2.10.1 新增：GT8 实机诊断包（2026-10-05）暴露的盲区 ═══
        # 这几个模块此前完全没被识别，但实测它们才是「CPU 频率被反复改动」的真凶候选人：
        # 诊断包里 sysfs.bak 记录到 cpu0-5 的 scaling_min_freq 被抬到 1785600、
        # cpu6-7 抬到 3072000（硬件最低是 384000/1017600）—— 抬 min_freq 锁高频
        # 正是「性能调度类」工具的手法，而不是温控限频。
        scene|scene_systemless|*Scene*)
            echo "$1|$2|$3|high|Scene 系性能调度：自带 CPU/GPU 频率与温控策略，会与 UNLOCK_FREQ 争抢 scaling_{min,max}_freq（实机表现为频率被反复改写、限频/解锁来回抖动）；两者目标可重叠但控制权互斥，建议只留一个"
            return 0 ;;
        muronggameopt|*游戏优化*|*GameOpt*)
            echo "$1|$2|$3|medium|慕容游戏优化系：面向游戏场景调整频率/调度策略，可能与 UNLOCK_FREQ 的频率上限压制互相覆盖（注意它与「慕容 ColorOS 附加模块 murongltpo」是两个不同模块）"
            return 0 ;;
        # 注意：这里刻意**不用** *batt* 这种宽通配 —— 它会把 combat 之类无关模块
        # 也判成电池工具（假阳性比漏报更消耗信任）。只列已知的电池工具名。
        fopbatt|batt_tools|battery_tools|*BatteryTool*)
            echo "$1|$2|$3|medium|电池类工具：可能读写电池温感 / GAUGE 相关节点，与本模块的 BATT_T 欺骗、OPPO_GAUGE 写入存在资源重叠，请确认其是否也改电池温度上报"
            return 0 ;;
        adreno_gpu_driver|*adreno*|*Adreno*)
            echo "$1|$2|$3|medium|Adreno GPU 驱动模块：可能替换/调整 GPU 频率表或 devfreq 节点，与本模块的 GPU_MAX_CLK / kgsl 频锁存在重叠"
            return 0 ;;
    esac
    # 二改包常改 id 但保留原名 —— 按名称兜底
    case "$2" in
        *Horae*)       echo "$1|$2|$3|high|HORAE 系模块：争抢同一批 XML 配置与 horae 服务"; return 0 ;;
        *"Extreme GT"*) echo "$1|$2|$3|high|Extreme GT 系模块：争抢同一批 XML 配置"; return 0 ;;
        *Moka*)        echo "$1|$2|$3|high|Moka 系模块：horae 停止指令与本机冲突"; return 0 ;;
        # v2.8.9：二改包常改 id 但保留原名
        *显示优化*)      echo "$1|$2|$3|medium|ColorOS 显示优化系模块：整份替换 oplus_vrr_config.json（上限 120Hz，GT8 为 144Hz）"; return 0 ;;
    esac
    return 1
}

# ── Tier B：关键词命中，可能同类但需人工确认 ────────────────────
match_keyword() {                    # $1=id  $2=name  $3=version
    case "$1$2" in
        *thermal*|*Thermal*|*THERMAL*|*温控*|*去温控*|*散热*|*降温*|*狂暴*|*throttle*|*Throttle*)
            echo "$1|$2|$3|medium|名称或 ID 含温控关键词，可能同样操作 thermal 节点/配置文件，请自行确认"
            return 0 ;;
    esac
    return 1
}

# ── Tier C：按「资源占用」扫描（v2.8.6 新增）───────────────────
#   思路来自第三方模块「慕容 ColorOS 附加模块」的 check_conflict_modules：
#   认不出模块身份时，改看它到底往哪些资源上写。
#   与 Tier A/B 的区别：A/B 认身份，C 认证据 —— 能抓到没见过的模块。
#   ⚠ 原实现不可直接复用，已知缺陷（本库已规避）：
#       · grep -q 'a' 'b' 'c' file —— 只有第 1 个是模式，其余被当文件名（实测）
#       · grep -m1 'id=' 无行首锚点，会误命中 versionId= / #id=
#       · 命中后直接 rm -rf 对方目录（本库只告警，绝不改动他人文件）
#       · 用 getevent 阻塞等音量键 —— KSU 在 App 内安装时无人应答，会挂死安装
#
#   实现约束（否则会拖慢安装 / 误报）：
#       · 只扫 *.sh / *.prop / *.rc：XML/JSON 配置不写节点，扫了只会污染结果
#       · grep -F 固定串：不做正则，避免把 sysfs 路径的 '.' 当通配符
#       · 两段式：先用「一次 grep 带全部关键字」判断有没有，命中才逐 token 定位。
#         常见情况是「没命中」→ 每文件仅 1 次 fork；只有真命中才付 10 次。
#         （不用 `grep -o` 一把梭：toybox 的 -o 支持情况不一致，命中即丢结果）
#       · -size -512k：跳过大型脚本/配置，避免整包 IO
#       · 结果 sort -u：同一 token 只报一次
scan_resource_hits() {            # $1=模块目录；stdout=命中的 token（去重）
    [ -d "$1" ] || return 0
    find "$1" -type f \( -name '*.sh' -o -name '*.prop' -o -name '*.rc' \) \
         -size -512k 2>/dev/null |
    while IFS= read -r _f; do
        grep -q -F -e emul_temp -e /proc/shell-temp -e thermal_zone \
                    -e cooling_device -e scaling_max_freq -e horae -e orms \
                    -e sys_thermal -e game_thermal -e max_gpu_clk \
                    "$_f" 2>/dev/null || continue
        for _t in emul_temp /proc/shell-temp thermal_zone cooling_device \
                  scaling_max_freq horae orms sys_thermal game_thermal max_gpu_clk; do
            grep -q -F -e "$_t" "$_f" 2>/dev/null && echo "$_t"
        done
    done | sort -u
}

#  ── 字段净化（v2.10.3）─────────────────────────────────────────
#  本库用 '|' 做字段分隔，但**第三方模块的 name 里就可能含 '|'** ——
#  实机证据（2026-10-06 诊断包）：adreno_gpu_driver 的 name 是
#  `Adreno™ 8xx GPU Drivers （ANGLE|Game driver）`，导致输出行从 5 段变 7 段，
#  下游 `IFS='|' read -r id name ver risk note` 全部错位：
#    · 日志打成 `⚠ 冲突模块[Full]: ... (adreno_gpu_driver) Game driver） — v2.0|medium|...`
#    · WebUI 冲突卡片的风险色与备注也被截断
#  在**读入时**净化一次，下游（日志、WebUI、诊断包）就都安全了。
#  用 tr 而非 bash 的 ${var//x/y}：本文件要被 toybox/mksh/busybox sh 执行。
_san_field() { printf '%s' "$1" | tr '|\r\n' '///'; }

#  ── 主入口：逐行输出命中的模块 ─────────────────────────────────
detect_conflicts() {
    [ -d "$MODULES_DIR" ] || return 0
    for _d in "$MODULES_DIR"/*; do
        [ -f "$_d/module.prop" ] || continue
        # 已禁用 / 待移除的模块不会运行，不构成冲突
        [ -e "$_d/disable" ] && continue
        [ -e "$_d/remove" ]  && continue
        _id=""; _nm=""; _ver=""
        while IFS='=' read -r _k _v; do
            case "$_k" in
                id)      _id="$_v"  ;;
                name)    _nm="$_v"  ;;
                version) _ver="$_v" ;;
            esac
        done < "$_d/module.prop"
        [ -n "$_id" ] || _id=$(basename "$_d")
        [ -n "$_nm" ] || _nm="$_id"
        _id=$(_san_field "$_id")
        _nm=$(_san_field "$_nm")
        _ver=$(_san_field "$_ver")
        # 跳过自身（覆盖升级 / 用户改名两种场景）
        case "$_id" in "$SELF_ID"|realme-gt8-sukisu*) continue ;; esac
        case "$_nm" in *"GT8 ThermalRemove"*) continue ;; esac
        match_known   "$_id" "$_nm" "$_ver" && continue
        match_keyword "$_id" "$_nm" "$_ver" && continue
        # Tier C：身份认不出，就看它有没有碰同一批资源（默认关闭，见 SCAN_RESOURCES）
        if [ "${SCAN_RESOURCES:-0}" = "1" ]; then
            _hits=$(scan_resource_hits "$_d")
            [ -n "$_hits" ] && \
                echo "$_id|$_nm|$_ver|low|脚本/属性里出现温控资源关键字：$(echo "$_hits" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        fi
    done
    return 0
}

# ── 人可读输出（供 ui_print / action.sh 使用）────────────────────
#   $1 = 每行前缀（如 "  "）；无命中时不输出任何内容
print_conflicts() {
    detect_conflicts | while IFS='|' read -r _id _nm _ver _rk _nt; do
        [ -n "$_id" ] || continue
        case "$_ver" in v*|V*|'') _vt="$_ver" ;; *) _vt="v$_ver" ;; esac
        if [ "$_rk" = "high" ]; then
            echo "${1}⚠ 高危: $_nm${_vt:+ ($_vt)}"
        else
            echo "${1}· 疑似: $_nm${_vt:+ ($_vt)}"
        fi
        echo "${1}   id=$_id"
        echo "${1}   $_nt"
    done
}
