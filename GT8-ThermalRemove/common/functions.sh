#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════
#  GT8 ThermalRemove（真我GT8 / SM8750）—— 公共函数库
#
#  策略（由强到弱，参考 HORAE Extreme 思路重构）：
#    1. emul_temp 温度欺骗：让温控引擎读到低温，达不到任何阈值 → 不限频
#       这是主手段，比"停服务 / 清配置"温和且有效
#    2. 安装时改写 OPPO/realme 私有温控配置阈值（customize.sh）
#    3. 归零 cooling_device、解锁 CPU/GPU 频率上限
#    4. 兜底：停用 thermal 相关 init 服务（默认关闭）
#
#  ══ 资源归属声明（v2.8）══════════════════════════════════════
#  本模块独占以下资源。改动任何一项前，先确认没有引入第二个写入方 ——
#  温控类模块互相覆盖时「最后执行者获胜」，故障现象随机且难以复现。
#
#    · /sys/class/thermal/thermal_zone*/emul_temp   唯一写入方（5s 周期重放）
#    · /sys/class/thermal/cooling_device*/cur_state 仅在 UNLOCK_CDEV=1 时写，
#      且永久跳过显示/背光类节点（见 is_display_cdev）
#    · /sys/devices/system/cpu/cpu*/cpufreq/scaling_{max,min}_freq
#    · /sys/class/kgsl/kgsl-3d0/{max_pwrlevel,max_gpu_clk,max_clock_mhz}
#    · /proc/shell-temp                             仅 OPPO_SHELL_TEMP=1 时写
#    · /proc/oplus-votable/GAUGE_UPDATE             仅 OPPO_GAUGE=1 时写
#    · horae 服务（dumpsys horae testmode）         仅 HORAE_TESTMODE=1 时调用
#    · vendor.oplus.ormsHalService-aidl-default     仅 DISABLE_ORMS=1 时停
#    · patched/thermal、patched/extra bind mount    由 mount_config_overlays 独占
#
#  ══ 单一轮询点约束（v2.8）════════════════════════════════════
#  所有周期性行为必须挂在 service.sh 的那一个 while 循环里。
#  不要为单个功能新开 `while true` / `( sleep N; ... ) &` —— 多一个循环就多一处
#  互相覆盖与 fork 开销的来源。开机 60s 的自检也已并进主循环（VERIFY_TICK）。
# ═══════════════════════════════════════════════════════════════

MODDIR="${MODDIR:-${0%/*}}"
# 兜底：上层没传且 ${0%/*} 拿不到目录时，退回标准安装路径
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove
PERSIST_DIR="/data/adb/thermal_remove"
SYSFS_BAK="$PERSIST_DIR/sysfs.bak"
PROP_BAK="$PERSIST_DIR/prop.bak"
MOUNT_LIST="$PERSIST_DIR/mounts.list"
STATE_FILE="$PERSIST_DIR/state"
LOG_FILE="$PERSIST_DIR/thermal_remove.log"
# 欺骗记账（v2.8.2）：apply_spoof 每次写成功的温感记成 dir|value 一行。
# 判定「是否欺骗中」必须以它为准 —— 部分厂商内核 set_emul_temp 走驱动私有
# 路径，sysfs 回读 emul_temp 恒为 0，回读判定的结果是「欺骗实际生效但
# 全部被判成未欺骗」（实机：欺骗中显示 0、真实温度探测从未被触发）。

# v2.8.12：CR 字符在运行时生成。**不要**在源码里嵌字面 \r —— 实测它经过
# 某些文本写入路径会被规范化成 \n，直接把 case 那行截断成非法语法（曾导致死循环）。
CR=$(printf '\r')
SPOOF_LIST="$PERSIST_DIR/spoof.list"

# ═══ v2.12.0 新增路径 ═══════════════════════════════════════════
# 温度保险丝触发记录（每行：时间 线路=真实温度）。只追加，用于诊断与界面展示；
# 不参与判定 —— 判定用进程内的 _FUSE_TICKS 冷却计数（零 fork）。
FUSE_LOG="$PERSIST_DIR/fuse.log"
# 真实温度探测的恢复标记：写 0 前落盘「目录|伪装值」，恢复后清除。若探测/采样进程
# 中途被杀，下一次会先按它自愈（否则该温感的欺骗就一直停在 0）。
# v2.12.0 起 api.sh 的真实温度探测与 functions.sh 的保险丝采样**共用**这一个文件，
# 路径必须与 api.sh 的默认值保持一致。
REAL_ZERO_MARK="$PERSIST_DIR/.real_zeroed"
# 开机尝试计数：post-fs-data 每次 +1，boot-completed 清零。
# 连续 BOOT_FAIL_LIMIT 次没走到 boot-completed（异常/崩溃/开不了机）→ 自动安全模式。
# 这是 KernelSU 模块的通用自救惯例：宁可少一次去温控，也不要卡开机。
BOOT_TOKEN="$PERSIST_DIR/.boot_try"
# 安全模式标记（内容为触发时间）：被用户手动切回 on/dynamic 时清除。
SAFE_MODE_MARK="$PERSIST_DIR/.safe_mode"

# v2.8.13 省电：缓存失效检测用的时间戳标记文件。
# 配置/列表/备份文件几乎不变，没必要每 5 秒重新解析一遍；用 `[ f -nt stamp ]`
# （test 内建，零 fork）判断是否真变了，变了才重解析并用 `: > stamp` 打时间戳
# —— 冒号是内建命令，配合重定向更新 mtime，不产生任何 fork。
CONF_STAMP="$PERSIST_DIR/.conf_stamp"
LIST_STAMP="$PERSIST_DIR/.list_stamp"
BAK_STAMP="$PERSIST_DIR/.bak_stamp"

# ═══ v2.8.13 运行时状态变量索引（仅进程内，不落盘；首次使用处初始化）═══════
#   _CONF_LOADED / _CONF_TICK           load_conf  配置缓存：已加载标记 + 强制刷新计数
#   _LIST_VALID / _LIST_TICK            _he_refresh 列表缓存：已缓存标记 + 强制刷新计数
#   _HE_PROT / _HE_GAME                 _he_refresh 保护/游戏列表「是否有有效条目」缓存
#   SYSFS_BAK_INDEX / _BAK_INDEX_LOADED sysfs_set  备份去重索引（|p1||p2| 形式）+ 载入标记
#   _SPOOF_LOG_SIG / _SPOOF_LOG_N       apply_spoof 日志去重：上次签名 + 心跳计数
#   _SPOOF_FAILED                       maintain_state 欺骗重放是否全失败（供 service.sh 提前重试）
#   _CHG / DECIDE_RESULT / _ZTV / _GCAP get_charging_into / decide_state_into /
#                                       zone_target_into / gpu_cap_target_into 的「写结果」出口
#   全部以 _ 前缀命名，避免与配置键（大写）与函数局部变量撞名。
#
# v2.9.2 变更：CPU 限频功能（CPU_LIMIT_MODE / LIMIT_*_MHZ / cpu_topology /
#   _freq_best_into / cpu_max_cap_into）因实机未达预期已整体移除。CPU 频率上限
#   恢复为「恒等于 cpuinfo_max_freq」（随 UNLOCK_FREQ 总开关），即 v2.8.12 语义。
#   新增 gpu_devfreq_cap —— unlock_perf / reapply_perf 共用的 GPU 上限压制。
# ════════════════════════════════════════════════════════════════
# v2.8.11：oplus_vrr_config.json 里 hw_nit_limit 等字段的原厂值（安装期写入）
VRR_BASE="$PERSIST_DIR/vrr_baseline.list"
# v2.8.8：inputflinger 线程提权 —— 原 nice 值备份（tid|原nice）与「已处理进程」标记。
# 备份用来精确还原（而不是一刀切写回 0）：线程的原始 nice 未必是 0。
TOUCH_BAK="$PERSIST_DIR/touch_thread.bak"
TOUCH_MARK="$PERSIST_DIR/.touch_thread.pid"

MODE_CONF="$MODDIR/mode.conf"
SPOOF_CONF="$MODDIR/spoof.conf"
GAME_LIST="$MODDIR/game_list.conf"
PROTECT_LIST="$MODDIR/protect_list.conf"

POLL_SECONDS=5
RES_SPOOF_TICKS=6          # 兼容旧配置：按 tick 计的重放上限（保留以防被外部引用）
VERIFY_TICK=12             # 开机后第 12 个 tick 做一次欺骗校验（5s × 12 ≈ 60s）

# ═══ v2.8.13 省电：把「检测」与「维护」解耦 ═══════════════════
# 原实现每 6 个 tick（30s）跑一次**全量** apply_state 1：find + 逐文件 awk、
# unlock_perf 的逐核 sysfs_set、83 个温感的 cat、pidof、mount 校验……
# 而其中绝大多数步骤在「状态没变」时根本无事可做 —— 挂载还在、服务没被拉起、
# 优先级也没丢。真正需要高频的只有一件事：**充电/前台状态检测**（安全侧），
# 它必须保持 5 秒。于是拆成两层：
#
#   检测层 POLL_SECONDS=5   只做零 fork 的轻量读取：配置 mtime、充电状态、
#                           状态文件。→ 唤醒次数与实时性完全不变。
#   维护层 MAINT_SECONDS=120 重放欺骗值 + 压制频锁 + 补提权 + 校验挂载。
#                           → fork 次数降到约 1/24。
#
# 三个值都可以写进 mode.conf 覆盖；设 MAINT_SECONDS=30 即回到 v2.8.12 节奏。
MAINT_SECONDS=120          # 完整维护周期（秒）：重放欺骗值 + 补提权 + 校验挂载
PERF_REFRESH_SECONDS=30    # 仅 reapply_perf 的周期（秒）；0 = 只在维护时做
                           # （它零 fork，只是 16 次 sysfs 读，保持 30s 更稳）
LOG_HEARTBEAT=12           # 欺骗重放日志：每 N 次维护记一条；0 = 只在条数变化时记
CONF_FORCE_TICKS=12        # 配置/列表缓存的强制刷新兜底（12 × 5s = 60 秒）
#   为什么需要兜底：`-nt` 只比 mtime 的**秒**，同一秒内的连续保存会漏检
#   （WebUI 连点两个开关就是这种场景）。60 秒是「漏检窗口」与「解析成本」的
#   折中 —— 全量解析一天 1440 次（原本 17280 次），成本约 4 秒 CPU/天。

# 冲突检测库：纯函数、零副作用。安装期的 customize.sh 会单独 source 同一份实现，
# 保证「安装期告警」与「运行时诊断」用的是同一套判定规则。
MODULES_DIR="${MODULES_DIR:-/data/adb/modules}"
SELF_ID="${SELF_ID:-realme-gt8-sukisu-thermal-remove}"
. "$MODDIR/common/conflicts.sh" 2>/dev/null
# v2.13.2（A2）：配置键唯一事实源（schema_file / schema_default / schema_valid）
. "$MODDIR/common/schema.sh" 2>/dev/null

# v2.9.3 修复：source-time 副作用闸门。
# 本文件被 6 处入口 source，其中 api.sh 的 get_verify、action.sh 的部分诊断命令
# 只需要本文件里的**函数**（dump_temp / load_conf 等），并不想写磁盘。
# 但下面三行是顶层语句，一 source 就执行：mkdir 建目录、创建/轮转日志。
# 后果：`api.sh --verify`（一个名义上的只读校验）会把 >256KB 的日志直接清空，
# 用户点「校验欺骗」就可能丢掉刚攒下的运行日志 —— 排查时最难接受的那种副作用。
# 现在：只有显式设置 TR_SIDE_EFFECTS=1 的入口（service.sh / customize.sh /
# uninstall.sh / post-fs-data.sh / boot-completed.sh / thermal_spoof.sh）才执行；
# 只读诊断入口（api.sh）不设置，从而零副作用。默认为 0（安全侧）。
if [ "${TR_SIDE_EFFECTS:-0}" = "1" ]; then
    mkdir -p "$PERSIST_DIR" 2>/dev/null
    [ -f "$LOG_FILE" ] || : > "$LOG_FILE"
    [ "$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')" -gt 262144 ] 2>/dev/null && : > "$LOG_FILE"
fi

# ── 系统版本 ──────────────────────────────────────────────────
ANDROID_REL="$(getprop ro.build.version.release 2>/dev/null)"
ANDROID_SDK="$(getprop ro.build.version.sdk 2>/dev/null)"
IS_A16=0
[ -n "$ANDROID_SDK" ] && [ "$ANDROID_SDK" -ge 36 ] 2>/dev/null && IS_A16=1

# ── 日志（v2.10.0：分级）────────────────────────────────────────
# 级别：0=DEBUG 1=INFO 2=WARN 3=ERROR。阈值由 mode.conf 的 LOG_LEVEL 决定
# （可写 debug/info/warn/error，也可写 0-3；默认 info）。
#
# 低于阈值的**连行都不拼**：注意这顺带省掉了 `date` 这个外部命令的 fork ——
# 即 DEBUG 日志在 info 阈值下是零成本的。这是分级附带的性能收益，
# 也是为什么判断放在 `date` 之前。
#
# 输出格式：[MM-DD HH:MM:SS] [LVL] 正文
#   用 3 字母标签而非全称：日志要在手机小屏上看，且便于 `grep '\[ERR\]'` 过滤。
LOG_LEVEL_NUM=1

# ── v2.10.1：早期启动的时钟兜底 ─────────────────────────────────
# post-fs-data 阶段 RTC 往往还没被系统同步，`date` 会返回 1970 年附近的值。
# 真机诊断包实测：post-fs-data 的日志打成了 [02-17 19:31:58]，与几秒后
# service 的 [10-05 23:06:42] 排在一起 —— 看起来像"一条 1970 年的陈年日志"，
# 读日志的人会直接懵（其实是"刚刚开机时"）。
# 这里在加载期探测一次（一次 fork）：年份不在 2020-2099 就认为时钟未就绪，
# 改用 [BOOT] 标记。顺带省掉这些早期日志的 date fork。
_LOG_TIME_OK=1
case "$(date +%Y 2>/dev/null)" in
    20[2-9][0-9]) ;;          # 2020-2099：时钟正常
    *) _LOG_TIME_OK=0 ;;      # 1970 等：RTC 未同步
esac
_LOG_SEQ=0

_log_emit() {
    _le_lv="$1"; shift
    [ "$_le_lv" -ge "${LOG_LEVEL_NUM:-1}" ] 2>/dev/null || return 0
    case "$_le_lv" in
        0) _le_t=DBG ;;
        2) _le_t=WRN ;;
        3) _le_t=ERR ;;
        *) _le_t=INF ;;
    esac
    if [ "$_LOG_TIME_OK" = "1" ]; then
        echo "[$(date '+%m-%d %H:%M:%S')] [$_le_t] $*" >> "$LOG_FILE"
    else
        _LOG_SEQ=$((_LOG_SEQ + 1))
        echo "[BOOT +${_LOG_SEQ}] [$_le_t] $*" >> "$LOG_FILE"
    fi
}

log_debug() { _log_emit 0 "$@"; }
log_info()  { _log_emit 1 "$@"; }
log_warn()  { _log_emit 2 "$@"; }
log_error() { _log_emit 3 "$@"; }
# 向后兼容：log_print 等价于 log_info。既有调用点保持可用，
# 但新代码应按语义显式选级别。
log_print() { _log_emit 1 "$@"; }

# 日志级别归一化：文字或数字 → LOG_LEVEL_NUM(0-3)。
# 无法识别一律回落 info —— 配置写错绝不能让日志静默消失（那比多打日志危险得多）。
_log_level_norm() {
    case "$1" in
        debug|DEBUG|Debug|0)         LOG_LEVEL_NUM=0 ;;
        warn|WARN|Warn|warning|2)    LOG_LEVEL_NUM=2 ;;
        error|ERROR|Error|err|3)     LOG_LEVEL_NUM=3 ;;
        *)                           LOG_LEVEL_NUM=1 ;;
    esac
}

# ── 冲突自检：把命中的其他温控模块写进日志（只记录，不改任何状态）──
log_conflicts() {
    [ "$CHECK_CONFLICTS" = "1" ] || return 0
    command -v detect_conflicts >/dev/null 2>&1 || return 0
    _c=$(detect_conflicts 2>/dev/null)
    if [ -z "$_c" ]; then
        log_info "✓ 冲突自检：未检测到其他温控模块"
        return 0
    fi
    # v2.10.3：日志只记「风险级别 + 模块身份」，不再把整行（含长备注）塞进日志 ——
    # 原实现打的是 `[$_rk]: $_nm ($_id) $_ver — $_nt`，备注动辄上百字，一次开机
    # 就刷出好几行超长 WRN，把真正的状态变更淹没。完整备注在 WebUI 冲突卡片与
    # `sh action.sh conflicts` 里都能看到，日志留简洁身份即可。
    # 注意：下面 while 走管道 → 循环体在子 shell 里，变量不回传，
    # 所以计数必须在循环**之外**单独算（别把 _n 写在循环里再在外面读）。
    _n=$(printf '%s\n' "$_c" | grep -c .)
    printf '%s\n' "$_c" | while IFS='|' read -r _id _nm _ver _rk _nt; do
        [ -n "$_id" ] || continue
        log_warn "⚠ 冲突模块[$_rk]：$_nm ($_id $_ver)"
    done
    log_info "  共 $_n 个（详情：WebUI 冲突卡片 或 sh action.sh conflicts）"
}

# ── 配置项读取（KEY=VALUE，支持 # 注释与引号）──────────────────
# v2.8.4：去壳改用纯 shell 实现（_strip），省掉两次 sed + 一个管道。
# 语义与原 sed 三段式严格等价（尾部空白 → 首双引号 → 尾双引号），
# 已用 6 组边界值（含空值/纯空白/内嵌引号/前后空格）对拍验证。
_strip() {
    _sv="$1"
    # v2.8.12：把 \r 也一并剥掉。原实现只去尾空格与尾制表符，配置一旦被存成 CRLF
    # （Windows 记事本、第三方编辑器、经电脑中转的文件），值尾就会带上 \r ——
    # 于是 [ "$UNLOCK_FREQ" = "1" ] 恒为假，**开关静默失效且毫无提示**。
    # 项目里 tr -d '\r' 此前只用在 spoof.list 这类数据文件上，配置解析这一侧漏了。
    #
    # 写成「剥一轮，变了就再剥一轮」：三种尾字符相互遮挡时（如 "1 \t\r"）
    # 顺序的单趟剥离会留下残余，反复剥离才能收敛到干净值。
    # 注意：三个 case 必须**各自独立**，不能合并成 `*" "|*"\t"|*"$CR")` ——
    # 那个多模式写法实测在 dash 下会误匹配（连 "1" 都命中 → 削成空 → 死循环）。
    while :; do
        _st_changed=0
        case "$_sv" in *" ")     _sv="${_sv% }";  _st_changed=1 ;; esac
        case "$_sv" in *"	")     _sv="${_sv%	}";  _st_changed=1 ;; esac
        case "$_sv" in *"$CR")   _sv="${_sv%?}"; _st_changed=1 ;; esac
        [ "$_st_changed" = "1" ] || break
    done
    case "$_sv" in '"'*) _sv="${_sv#\"}" ;; esac
    case "$_sv" in *'"') _sv="${_sv%\"}" ;; esac
}

# 单键读取：只跑一次 sed，取值+去壳都在 shell 内完成
conf_get() {
    _f="$1"; _k="$2"; _d="$3"
    _v=$(sed -n "s/^$_k=//p" "$_f" 2>/dev/null | head -n 1)
    if [ -n "$_v" ]; then
        _v=${_v%%#*}     # v2.13.0：剥行内注释，与 load_conf 保持一致
        _strip "$_v"
        _v="$_sv"
    fi
    [ -z "$_v" ] && _v="$_d"
    echo "$_v"
}

load_conf() {
    # v2.8.13 省电：v2.8.12 已把解析做成纯 shell（零 fork），但每 5 秒全量解析
    # 两份配置（≈250 行、40+ 个键）仍是一笔纯 CPU 开销，一天 17280 次。
    # 配置只在用户改设置时才会变，用 mtime 判断（`[ f -nt stamp ]` 是 test 内建，
    # 零 fork）：没变就直接复用上一轮的变量，变过才重新解析。
    # 对外契约不变：调用后所有配置变量依然可用，且**改动后最多 1 个 tick 生效**
    # —— 与「每轮全量解析」的生效时机完全一致（原来是下一轮读到新值）。
    # 兜底：即使 mtime 没变，每 CONF_FORCE_TICKS 轮强制解析一次，覆盖
    #   「文件被替换成 mtime 更旧的副本」这类 -nt 看不见的情况。
    _lc_need=1
    if [ "${_CONF_LOADED:-0}" = "1" ]; then
        _lc_need=0
        _CONF_TICK=$(( ${_CONF_TICK:-0} + 1 ))
        [ "$MODE_CONF"  -nt "$CONF_STAMP" ] && _lc_need=1
        [ "$SPOOF_CONF" -nt "$CONF_STAMP" ] && _lc_need=1
        if [ "${_CONF_TICK:-0}" -ge "${CONF_FORCE_TICKS:-12}" ] 2>/dev/null; then
            _lc_need=1; _CONF_TICK=0
        fi
    else
        _CONF_TICK=0
    fi
    [ "$_lc_need" = "1" ] || return 0

    # v2.8.12 性能：原实现 25 次 conf_get = 25×(sed+head) = 50 次 fork，
    # 每轮主循环（5s）跑一次 → 一天约 86 万次 fork，只为读一份几乎不变的配置。
    # 现改为纯 shell 一次遍历：read 是内建命令，赋值走 case 白名单（不用 eval，避免注入）。
    # 行为保持：只取**第一次**出现的键（与原 sed -n 's/^k=//p' | head -1 一致），
    # 空值回落到默认值；行尾空白与首尾引号处理沿用 _strip。

    # v2.13.2（A2）：默认值统一到 schema（加键只改 schema.sh，不再维护这里的逐行赋值）
    schema_apply_defaults
    # 内部状态键（不进 schema，仅 load_conf 使用）
    _MAINT_EXPLICIT=0
    _RES_EXPLICIT=0
    # 保险丝采样等待（不进 conf，测试环境用环境变量覆盖为 0 跳过等待）
    FUSE_DELAY_MS=80

    _lc_seen=""
    for _lc_f in "$MODE_CONF" "$SPOOF_CONF"; do
        [ -f "$_lc_f" ] || continue
        # 注意 `|| [ -n "$_lc_ln" ]`：POSIX 下 read 遇到「最后一行没有换行符」
        # 会返回非 0，只用 `while read` 会把该行**整行丢弃**
        # （实测：文件是 "MODE=off" 且无尾换行 → 读不到，回落成 dynamic）。
        # 手工编辑配置很容易不写尾换行，这个兜底必须有。
        while IFS= read -r _lc_ln || [ -n "$_lc_ln" ]; do
            case "$_lc_ln" in ''|'#'*) continue ;; esac
            # v2.13.0：剥行内注释（首个 # 及其后）。此前 mode.conf 大量键带行内
            # 注释（如 FUSE_ENABLE=1  # 说明），值会被读成「1  # 说明」——
            # 数值键被净化回落默认、枚举/开关键判定失败（FUSE_ENABLE 因此恒「关闭」）。
            _lc_ln=${_lc_ln%%#*}
            case "$_lc_ln" in *=*) ;; *) continue ;; esac
            _kk=${_lc_ln%%=*}
            _lc_v=${_lc_ln#*=}
            case " $_lc_seen " in *" $_kk "*) continue ;; esac
            _strip "$_lc_v"
            # 废弃键兼容：v2.8.12 前的 RES_SPOOF_TICKS 不在 schema 里，单独处理
            case "$_kk" in
                RES_SPOOF_TICKS)
                    RES_SPOOF_TICKS=$_sv; _RES_EXPLICIT=1
                    _lc_seen="$_lc_seen $_kk"; continue ;;
            esac
            # v2.13.2（A2）：白名单统一到 schema（未登记键一律跳过）
            schema_file "$_kk" || continue
            case "$_kk" in
                MODE)               MODE=$_sv ;;
                GAME_PROTECT)       GAME_PROTECT=$_sv ;;
                STOP_SERVICES)      STOP_SERVICES=$_sv ;;
                UNLOCK_FREQ)        UNLOCK_FREQ=$_sv ;;
                OPPO_SHELL_TEMP)    OPPO_SHELL_TEMP=$_sv ;;
                OPPO_GAUGE)         OPPO_GAUGE=$_sv ;;
                HORAE_TESTMODE)     HORAE_TESTMODE=$_sv ;;
                DISABLE_ORMS)       DISABLE_ORMS=$_sv ;;
                TOUCH_BOOST)        TOUCH_BOOST=$_sv ;;
                TOUCH_THREAD_BOOST) TOUCH_THREAD_BOOST=$_sv ;;
                TOUCH_THREAD_NICE)  TOUCH_THREAD_NICE=$_sv ;;
                PATCH_THERMAL)      PATCH_THERMAL=$_sv ;;
                PATCH_EXTRA)        PATCH_EXTRA=$_sv ;;
                UNLOCK_CDEV)        UNLOCK_CDEV=$_sv ;;
                UNLOCK_GPU)         UNLOCK_GPU=$_sv ;;
                GPU_MAX_CLK)        GPU_MAX_CLK=$_sv ;;
                DISPLAY_PROTECT)    DISPLAY_PROTECT=$_sv ;;
                CHECK_CONFLICTS)    CHECK_CONFLICTS=$_sv ;;
                SCAN_RESOURCES)     SCAN_RESOURCES=$_sv ;;
                REPLACE_ENCRYPTED)  REPLACE_ENCRYPTED=$_sv ;;
                MAINT_SECONDS)        MAINT_SECONDS=$_sv;       _MAINT_EXPLICIT=1 ;;
                PERF_REFRESH_SECONDS) PERF_REFRESH_SECONDS=$_sv ;;
                LOG_HEARTBEAT)        LOG_HEARTBEAT=$_sv ;;
                CONF_FORCE_TICKS)     CONF_FORCE_TICKS=$_sv ;;
                LOG_LEVEL)            LOG_LEVEL=$_sv ;;
                FUSE_ENABLE)          FUSE_ENABLE=$_sv ;;
                FUSE_TEMP_BATT)       FUSE_TEMP_BATT=$_sv ;;
                FUSE_TEMP_SOC)        FUSE_TEMP_SOC=$_sv ;;
                FUSE_TEMP_SKIN)       FUSE_TEMP_SKIN=$_sv ;;
                FUSE_COOLDOWN)        FUSE_COOLDOWN=$_sv ;;
                BOOT_FAIL_LIMIT)      BOOT_FAIL_LIMIT=$_sv ;;
                SOC_T)              SOC_T=$_sv ;;
                SKIN_T)             SKIN_T=$_sv ;;
                CAM_T)              CAM_T=$_sv ;;
                BATT_T)             BATT_T=$_sv ;;
                SPOOF_BATT)         SPOOF_BATT=$_sv ;;
                SHELL_PROC_T)       SHELL_PROC_T=$_sv ;;
                BLACKLIST)          BLACKLIST=$_sv ;;
            esac
            _lc_seen="$_lc_seen $_kk"
        done < "$_lc_f"
    done

    case "$MODE" in always|dynamic|off) ;; *) MODE=dynamic ;; esac

    # 空值回落默认（原 conf_get 的 [ -z ] && _d 语义）
    [ -z "$MODE" ]              && MODE=dynamic
    [ -z "$GAME_PROTECT" ]      && GAME_PROTECT=0
    [ -z "$STOP_SERVICES" ]     && STOP_SERVICES=0
    [ -z "$UNLOCK_FREQ" ]       && UNLOCK_FREQ=1
    [ -z "$TOUCH_BOOST" ]       && TOUCH_BOOST=1
    [ -z "$TOUCH_THREAD_BOOST" ] && TOUCH_THREAD_BOOST=0
    [ -z "$TOUCH_THREAD_NICE" ] && TOUCH_THREAD_NICE=-19
    [ -z "$PATCH_THERMAL" ]     && PATCH_THERMAL=1
    [ -z "$DISPLAY_PROTECT" ]   && DISPLAY_PROTECT=1
    [ -z "$CHECK_CONFLICTS" ]   && CHECK_CONFLICTS=1
    [ -z "$SOC_T" ]             && SOC_T=29500
    [ -z "$SKIN_T" ]            && SKIN_T=29500
    [ -z "$CAM_T" ]             && CAM_T=29500
    [ -z "$BATT_T" ]            && BATT_T=29500
    [ -z "$SHELL_PROC_T" ]      && SHELL_PROC_T=29500

    # v2.8.13：兼容 v2.8.12 及更早 —— 老配置里手动调过 RES_SPOOF_TICKS 的，
    # 按「tick 数 × 轮询周期」折算成新的 MAINT_SECONDS，避免升级后重放频率
    # 被静默改掉。显式写了 MAINT_SECONDS 的以新键为准。
    if [ "${_RES_EXPLICIT:-0}" = "1" ] && [ "${_MAINT_EXPLICIT:-0}" != "1" ]; then
        case "$RES_SPOOF_TICKS" in
            ''|*[!0-9]*) ;;
            *) MAINT_SECONDS=$((RES_SPOOF_TICKS * POLL_SECONDS)) ;;
        esac
    fi

    # v2.8.13：省电相关的数值键参与算术比较（-ge），非数字会让 test 报
    # 「integer expression expected」并每轮刷一行 stderr。这里统一净化回落。
    case "$MAINT_SECONDS"        in ''|*[!0-9]*) MAINT_SECONDS=120 ;; esac
    case "$PERF_REFRESH_SECONDS" in ''|*[!0-9]*) PERF_REFRESH_SECONDS=30 ;; esac
    case "$LOG_HEARTBEAT"        in ''|*[!0-9]*) LOG_HEARTBEAT=12 ;; esac
    case "$CONF_FORCE_TICKS"     in ''|*[!0-9]*) CONF_FORCE_TICKS=12 ;; esac
    # v2.12.0：保险丝数值键同样要净化（它们参与 -gt/-le 算术，非数字每轮刷 stderr）
    case "$FUSE_TEMP_BATT"       in ''|*[!0-9]*) FUSE_TEMP_BATT=45000 ;; esac
    case "$FUSE_TEMP_SOC"        in ''|*[!0-9]*) FUSE_TEMP_SOC=80000 ;; esac
    case "$FUSE_TEMP_SKIN"       in ''|*[!0-9]*) FUSE_TEMP_SKIN=46000 ;; esac
    case "$FUSE_COOLDOWN"        in ''|*[!0-9]*) FUSE_COOLDOWN=120 ;; esac
    case "$BOOT_FAIL_LIMIT"      in ''|*[!0-9]*) BOOT_FAIL_LIMIT=3 ;; esac
    _log_level_norm "$LOG_LEVEL"
    case "$GPU_MAX_CLK"          in ''|*[!0-9]*) GPU_MAX_CLK=2147483647 ;; esac

    # 打时间戳：`: >` 只更新 mtime，零 fork（不能用 touch，那是外部命令）。
    # 只有长驻守护（CONF_PERSISTENT=1，即 service.sh）才打 —— 一次性进程
    # （action.sh / customize.sh / thermal_spoof.sh）打的话，会把自己完整解析的
    # 时刻刷成新 stamp，反而让主进程对「稍早的配置改动」漏检（见 service.sh）。
    [ "$CONF_PERSISTENT" = "1" ] && : > "$CONF_STAMP" 2>/dev/null
    _CONF_LOADED=1

    # 显式 return 0：函数末尾是 `[ -z ... ] && ...` 链，条件为假时整条返回 1，
    # 会让调用方拿到「失败」的退出码（无 set -e 时不致命，但契约该干净）。
    return 0
}

# ── sysfs 安全写入：写前备份原值 ──────────────────────────────
# v2.8.4：备份去重改用 awk 做「行首字面量比较」。
# 原实现 grep -q "^$_p=" 把路径当正则：sysfs 路径含大量 '.'（如
# /sys/class/kgsl/kgsl-3d0/…），'.' 会匹配任意字符，可能把不存在的节点
# 误判为已备份 → 真实原值没被记录，卸载时无法还原。
# 注意不能用 grep -F：它不支持 ^ 锚点，"max_freq=" 会子串命中
# "scaling_max_freq="，同样误判。awk 的 index($0,k)==1 才是行首字面量比较。
# v2.8.13 省电：原实现每次写入都 fork 一个 awk 去扫整份备份文件 ——
# unlock_perf 一轮要写 8 核 ×2 + GPU + devfreq ≈ 20 个节点，就是 20 次 awk。
# 改为进程内索引：已备份路径记成 `|p1|p2|…`，用 case 子串匹配判断（零 fork）。
# 索引失效条件（任一满足即重载）：首次使用、备份文件的 mtime 变新
#   —— mtime 变新说明别的进程动过它（典型是 action.sh 的 restore_sysfs 清空）。
# 语义与 awk 版严格等价：都只判断「该路径是否已备份过一次」。
SYSFS_BAK_INDEX=""
_BAK_INDEX_LOADED=0
_bak_index_load() {
    SYSFS_BAK_INDEX=""
    [ -f "$SYSFS_BAK" ] || return 0
    # 每个条目前后都带 '|'（形如 |p1||p2|）：只在一端加的话，**第一个**条目
    # 匹配不到 `"|路径|"`，会被当成没备份过而反复追加 —— 后果是把「已被我们
    # 改写的值」当成原值记进备份，卸载还原时写回错误的值。
    while IFS='=' read -r _bi_p _bi_v; do
        [ -n "$_bi_p" ] && SYSFS_BAK_INDEX="$SYSFS_BAK_INDEX|$_bi_p|"
    done < "$SYSFS_BAK"
    return 0
}
sysfs_set() {
    _p="$1"; _v="$2"
    [ -e "$_p" ] || return 1
    if [ "$_BAK_INDEX_LOADED" != "1" ] || [ "$SYSFS_BAK" -nt "$BAK_STAMP" ] 2>/dev/null; then
        _bak_index_load
        _BAK_INDEX_LOADED=1
        : > "$BAK_STAMP" 2>/dev/null
    fi
    # 定界符用 '|'：sysfs 路径不含它，`|路径|` 不会像裸子串那样误命中
    case "$SYSFS_BAK_INDEX" in
        *"|$_p|"*) ;;
        *)
            _ov=""
            read -r _ov < "$_p" 2>/dev/null
            echo "$_p=$_ov" >> "$SYSFS_BAK" 2>/dev/null
            SYSFS_BAK_INDEX="$SYSFS_BAK_INDEX|$_p|"
            : > "$BAK_STAMP" 2>/dev/null
            ;;
    esac
    echo "$_v" > "$_p" 2>/dev/null
}

restore_sysfs() {
    if [ -f "$SYSFS_BAK" ]; then
        while IFS='=' read -r _p _v; do
            [ -n "$_p" ] && [ -e "$_p" ] && echo "$_v" > "$_p" 2>/dev/null
        done < "$SYSFS_BAK"
        : > "$SYSFS_BAK"
        log_info "sysfs 已还原"
    fi
    # v2.9.2：GPU 频锁节点不在 SYSFS_BAK 里（它们被 chmod -w 锁过），
    # 必须单独解除只读 + 写回原值，否则卸载/关开关后 GPU 频率被锁死到重启。
    restore_locked_nodes
    return 0
}

# ── 判断内核是否支持温度仿真（emul_temp）───────────────────────
spoof_supported() {
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/emul_temp" ] && return 0
    done
    return 1
}

# ── 温感分类 → 目标欺骗温度 ───────────────────────────────────
# v2.8.13 省电：拆分出「算而不打印」的版本。
# 原 zone_target 靠 echo 返回值，调用处必须写 `$(zone_target …)` —— 命令替换
# 在 shell 里是**一个子 shell**，GT8 上 83 个温感 = 每轮 83 次 fork。
# 规则只在 _into 版里写一份，echo 版调它，避免两处规则走偏。
zone_target_into() {
    case "$1" in
        *batt*|*battery*|*usb*)        _ZTV=$BATT_T ;;
        *shell*|*skin*|*case*|*frame*) _ZTV=$SKIN_T ;;
        *cam*|*tof*|*flash*)           _ZTV=$CAM_T ;;
        *)                             _ZTV=$SOC_T ;;
    esac
}
zone_target() { zone_target_into "$1"; echo "$_ZTV"; }

is_blacklisted() {
    [ -z "$BLACKLIST" ] && return 1
    for _b in $BLACKLIST; do
        case "$1" in $_b) return 0 ;; esac
    done
    return 1
}

# ── 应用温度欺骗 ──────────────────────────────────────────────
# 写成功的温感记入 $SPOOF_LIST（dir|value），作为「欺骗中」判定的唯一事实来源。
# 不要改回「回读 emul_temp 判定」—— 见 SPOOF_LIST 上方说明。
# v2.8.13 省电（本函数是整个模块第二大开销，原实现一轮 ≈85 次 fork）：
#   · `cat "$_z/type"`        → `read -r` 内建，83 次 fork → 0
#   · `$(zone_target "$_ty")` → zone_target_into，83 次子 shell → 0
#   · `$(basename "$_z")`     → ${_z##*/} 参数展开，外部命令 → 0
#   · 周期性日志去重：重放时条数几乎不变，不再每 120s 写一行重复记录
# 行为完全不变：写入的值、跳过的温感、记账文件、返回值都与原来一致。
apply_spoof() {
    _n=0; _skip=0
    : > "$SPOOF_LIST.tmp" 2>/dev/null
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -f "$_z/temp" ] || continue
        if [ ! -e "$_z/emul_temp" ]; then
            _skip=$((_skip + 1))
            continue
        fi
        _ty=""
        read -r _ty < "$_z/type" 2>/dev/null
        [ -n "$_ty" ] || _ty=${_z##*/}
        is_blacklisted "$_ty" && continue
        case "$_ty" in
            *batt*|*battery*|*usb*)
                [ "$SPOOF_BATT" = "1" ] || continue
                ;;
        esac
        zone_target_into "$_ty"
        _tv=$_ZTV
        if echo "$_tv" > "$_z/emul_temp" 2>/dev/null; then
            _n=$((_n + 1))
            echo "$_z|$_tv" >> "$SPOOF_LIST.tmp" 2>/dev/null
        fi
    done
    mv -f "$SPOOF_LIST.tmp" "$SPOOF_LIST" 2>/dev/null
    oppo_nodes_on

    # 日志去重：只在「本次结果签名变了」时记录；此外每 LOG_HEARTBEAT 次
    # 补一条心跳（保留「模块还活着、还在重放」这一可观测证据）。
    # 原来每 30s 一行，一天 2880 行内容几乎完全相同 —— 纯日志 I/O 与 date fork。
    _as_sig="$_n/$_skip"
    _as_log=0
    if [ "$_as_sig" != "${_SPOOF_LOG_SIG:-}" ]; then
        _as_log=1
    else
        _SPOOF_LOG_N=$(( ${_SPOOF_LOG_N:-0} + 1 ))
        if [ "${LOG_HEARTBEAT:-12}" -gt 0 ] 2>/dev/null && \
           [ "${_SPOOF_LOG_N:-0}" -ge "${LOG_HEARTBEAT:-12}" ] 2>/dev/null; then
            _as_log=1; _SPOOF_LOG_N=0
        fi
    fi
    if [ "$_as_log" = "1" ]; then
        log_info "欺骗已应用：$_n 个温感${_skip:+，$_skip 个不支持 emul_temp}"
        _SPOOF_LOG_SIG=$_as_sig
    fi
    echo "$_n"
}

# ── 撤销温度欺骗（写 0 = 关闭仿真，恢复真实读数）───────────────
restore_spoof() {
    _n=0
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/emul_temp" ] || continue
        echo 0 > "$_z/emul_temp" 2>/dev/null && _n=$((_n + 1))
    done
    oppo_nodes_off
    : > "$SPOOF_LIST" 2>/dev/null
    log_info "欺骗已撤销：$_n 个温感"
}

# ── OPPO/realme 私有接口 ──────────────────────────────────────
oppo_nodes_on() {
    if [ "$OPPO_SHELL_TEMP" = "1" ] && [ -e /proc/shell-temp ]; then
        _i=0
        while [ "$_i" -le 9 ]; do
            echo "$_i $SHELL_PROC_T" > /proc/shell-temp 2>/dev/null
            _i=$((_i + 1))
        done
    fi
    if [ "$OPPO_GAUGE" = "1" ] && [ -d /proc/oplus-votable/GAUGE_UPDATE ]; then
        _gu=/proc/oplus-votable/GAUGE_UPDATE
        chmod 666 "$_gu/force_val" 2>/dev/null
        echo 1000 > "$_gu/force_val" 2>/dev/null
        chmod 666 "$_gu/force_active" 2>/dev/null
        echo 1 > "$_gu/force_active" 2>/dev/null
    fi
}

oppo_nodes_off() {
    if [ "$OPPO_GAUGE" = "1" ] && [ -d /proc/oplus-votable/GAUGE_UPDATE ]; then
        echo 0 > /proc/oplus-votable/GAUGE_UPDATE/force_active 2>/dev/null
    fi
}

# ── lock_val：写入后立即 chmod -w，阻止用户态守护进程改回 ────────
#    （来自 Extreme GT；只用于 GPU 节点，不用于 emul_temp 以免影响内核仿真管理）
#
# v2.9.2 修复（真实缺陷）：原实现 chmod -w 之后，**既不备份原值也不记录被锁节点**。
# 后果有两条，都很实在：
#   1. 卸载模块 / 关掉 UNLOCK_GPU 后，kgsl 节点仍是只读、值仍是解锁后的值 ——
#      节点要等重启才恢复，而重启后模块若没自动加载，用户会看到「GPU 频率被锁死」。
#   2. restore_sysfs 走的是备份文件，而这些节点从未进过备份，所以还原路径压根不覆盖它们。
# 现在：首次锁定时把「原值」记进 LOCK_BAK（复用 sysfs_set 的备份链，不需要另立
# 机制），并把节点路径记进 LOCKED_NODES；restore_locked_nodes 负责 chmod +w 后
# 写回原值。首次锁定判定用 LOCK_BAK 里是否已有该路径，和 sysfs_set 的索引同源。
LOCK_BAK="$PERSIST_DIR/gpu_lock.bak"
LOCKED_NODES="$PERSIST_DIR/gpu_locked.list"

lock_val() {
    _v="$1"; _p="$2"
    [ -e "$_p" ] || return 1
    umount "$_p" 2>/dev/null
    chmod +w "$_p" 2>/dev/null
    # 首次锁定才备份原值（后续重复调用不覆盖，否则会把改过的值当成原值）
    if ! grep -qF "$_p=" "$LOCK_BAK" 2>/dev/null; then
        _lv_orig=""
        read -r _lv_orig < "$_p" 2>/dev/null
        [ -n "$_lv_orig" ] && echo "$_p=$_lv_orig" >> "$LOCK_BAK" 2>/dev/null
    fi
    grep -qxF "$_p" "$LOCKED_NODES" 2>/dev/null || echo "$_p" >> "$LOCKED_NODES" 2>/dev/null
    echo "$_v" > "$_p" 2>/dev/null
    _rc=$?
    chmod -w "$_p" 2>/dev/null
    command -v restorecon >/dev/null 2>&1 && restorecon -R -F "$_p" >/dev/null 2>&1
    return $_rc
}

# 还原 lock_val 锁过的节点：先 chmod +w 解除只读，再写回原值。
# 在 restore_sysfs 之后调用（那时备份文件已清空，正好靠 LOCK_BAK 独立还原）。
restore_locked_nodes() {
    [ -f "$LOCK_BAK" ] || return 0
    while IFS='=' read -r _lp _lv; do
        [ -n "$_lp" ] || continue
        [ -e "$_lp" ] || continue
        chmod +w "$_lp" 2>/dev/null
        echo "$_lv" > "$_lp" 2>/dev/null
    done < "$LOCK_BAK"
    : > "$LOCK_BAK"
    : > "$LOCKED_NODES"
    log_info "GPU 频锁节点已解除只读并还原原值"
    return 0
}

# ── GPU 解锁：用 INT_MAX 表示"不限制" ──────────────────────────
# v2.8.13 功耗优化：新增 UNLOCK_GPU 独立开关 + GPU_MAX_CLK 甜点值。
#   · UNLOCK_GPU=0   → 完全不碰 GPU，只解锁 CPU（发热/耗电显著下降）
#   · GPU_MAX_CLK    → 频率上限（Hz）。默认 2147483647=不限制（原满血行为）；
#                      设甜点值（如 800000000=800MHz）可在性能与发热间折中。
#   ⚠ 单位假设 Hz，且 max_gpu_clk / max_clock_mhz 是 HORAE 继承的 legacy 接口，
#     SM8750 上真正生效的可能是 devfreq（见 unlock_perf / reapply_perf 里的
#     gpu_cap_target_into）。改完用 §验证命令确认哪个节点真的把频率压下来了。
# 计算 devfreq 目标档位：available_frequencies 里 ≤ GPU_MAX_CLK 的最大档；
# 上限设得过低（无档位满足）时回退到最低档，保证 GPU 至少可用。
#   $1 = available_frequencies 文件；结果写全局变量 _GCAP
gpu_cap_target_into() {
    _GCAP=""; _g_max=""; _g_min=""
    while IFS= read -r _afl || [ -n "$_afl" ]; do
        # 循环变量用 _gv（不叫 _f，避免与调用方外层 for _f 冲突）
        for _gv in $_afl; do
            case "$_gv" in ''|*[!0-9]*) continue ;; esac
            if [ -z "$_g_max" ] || [ "$_gv" -gt "$_g_max" ]; then _g_max=$_gv; fi
            if [ -z "$_g_min" ] || [ "$_gv" -lt "$_g_min" ]; then _g_min=$_gv; fi
            if [ "$_gv" -le "$GPU_MAX_CLK" ]; then
                if [ -z "$_GCAP" ] || [ "$_gv" -gt "$_GCAP" ]; then _GCAP=$_gv; fi
            fi
        done
    done < "$1" 2>/dev/null
    [ -n "$_GCAP" ] || _GCAP=$_g_min
    return 0
}

unlock_gpu() {
    # v2.9.2：关开关时把之前 lock_val 锁过的节点解锁并还原原值。
    # 原实现直接 return，导致「1 → 0」切换后节点仍是只读、值仍是解锁后的状态，
    # 用户只能靠重启恢复。现在切关即还原。
    if [ "$UNLOCK_GPU" != "1" ]; then
        restore_locked_nodes
        return 0
    fi
    lock_val 0 /sys/class/kgsl/kgsl-3d0/max_pwrlevel
    lock_val "$GPU_MAX_CLK" /sys/class/kgsl/kgsl-3d0/max_gpu_clk
    if [ "$GPU_MAX_CLK" = "2147483647" ]; then
        lock_val 2147483647 /sys/class/kgsl/kgsl-3d0/max_clock_mhz
    else
        lock_val $((GPU_MAX_CLK / 1000000)) /sys/class/kgsl/kgsl-3d0/max_clock_mhz
    fi
}

# ── 触控服务提优先级（改善跟手性）──────────────────────────────
touch_boost() {
    [ "$TOUCH_BOOST" = "1" ] || return 0
    for _n in vendor-oplus-hardware-touch-V2-service touchDaemon; do
        _pid=$(pidof "$_n" 2>/dev/null)
        [ -n "$_pid" ] && renice -n -19 -p "$_pid" 2>/dev/null
    done
}

# ── 触控：inputflinger 线程级提权（v2.8.8）────────────────────
#  为什么需要：上面的 touch_boost 只把厂商触控守护进程 renice 到 -19，
#  但事件分发并不在那两个进程里 —— 它在 inputflinger 的
#  InputReader（读事件）/ InputDispatcher（分发）/ InputClassifier（手势判定）
#  线程上。也就是说厂商服务提权了，交给系统之后的那半程还是默认优先级。
#
#  为什么只到 renice 为止（重要，不要"优化"成实时优先级）：
#    · SCHED_FIFO 不可抢占。评审过的两个第三方包用 chrt -f -p 99 把输入/SF
#      设成 FIFO，再叠加 sched_rt_throttle_us=0（RT 任务唯一的保险丝）——
#      任一 RT 线程死循环就是整机硬卡死，只能长按电源。
#    · 本模块不碰 sched_rt_throttle_us，也不用 chrt -f。
#  nice 值的代价可控：只影响 CFS 调度权重，不产生不可抢占路径；
#  进程重启自动失效，且这里存了原值可精确还原。
#
#  幂等：优先级设置随线程生命周期有效，同一个 inputflinger 实例只做一次，
#  主循环 5 秒一轮不会反复 renice（用 TOUCH_MARK 记录已处理的 pid）。

# 读线程当前 nice：/proc/<tid>/stat 第 19 字段。
# comm 字段可能含空格和括号，因此取**最后一个** ') ' 之后的内容再分词；
# 剩下第 1 个字段是 state（原第 3 字段），nice = 19 - 2 = 第 17 个。
tb_nice_of() {
    [ -r "/proc/$1/stat" ] || return 1
    IFS= read -r _tns < "/proc/$1/stat" 2>/dev/null || return 1
    _tns=${_tns##*') '}
    set -- $_tns
    [ $# -ge 17 ] || return 1
    shift 16
    echo "$1"
}

# 列出待提权的线程 tid：comm **精确匹配**，不做前缀/子串匹配（避免误伤同名服务）
touch_thread_list() {
    _tlp="$1"
    [ -n "$_tlp" ] && [ -d "/proc/$_tlp/task" ] || return 0
    for _td in "/proc/$_tlp"/task/*; do
        _tid=${_td##*/}
        case "$_tid" in ''|*[!0-9]*) continue ;; esac
        # v2.8.13 省电：read 内建替代 cat（inputflinger 有 20+ 线程 = 20+ 次 fork）
        _c=""
        read -r _c < "$_td/comm" 2>/dev/null || continue
        case "$_c" in
            InputReader|InputDispatcher|InputClassifier) echo "$_tid" ;;
        esac
    done
}

touch_thread_boost() {
    # 开关被关掉时负责收尾：把此前提过的线程还原回去（这样 WebUI 上关掉开关
    # 也能在 5 秒内生效，不必等重启）
    if [ "$TOUCH_THREAD_BOOST" != "1" ]; then
        [ -f "$TOUCH_MARK" ] && touch_thread_restore
        return 0
    fi
    _tb_pid=$(pidof -s inputflinger 2>/dev/null)
    [ -n "$_tb_pid" ] || return 0
    # 同一进程实例已处理过 → 直接返回（优先级在该进程存活期间持续有效）
    [ "$(cat "$TOUCH_MARK" 2>/dev/null)" = "$_tb_pid" ] && return 0
    # pid 变了说明进程重启过：旧 tid 已失效，先按备份尽力还原，再重新记账
    touch_thread_restore
    : > "$TOUCH_BAK" 2>/dev/null
    _tb_n=0
    for _tid in $(touch_thread_list "$_tb_pid"); do
        _old=$(tb_nice_of "$_tid") || continue
        renice -n "$TOUCH_THREAD_NICE" -p "$_tid" >/dev/null 2>&1 || continue
        echo "$_tid|$_old" >> "$TOUCH_BAK" 2>/dev/null
        _tb_n=$((_tb_n + 1))
    done
    echo "$_tb_pid" > "$TOUCH_MARK" 2>/dev/null
    [ "$_tb_n" -gt 0 ] && \
        log_info "触控线程提权：inputflinger(pid=$_tb_pid) $_tb_n 个线程 → nice $TOUCH_THREAD_NICE"
    return 0
}

touch_thread_restore() {
    # 无备份也无标记 → 从未提过权，直接返回（主循环每 5 秒会走到这里）
    [ -s "$TOUCH_BAK" ] || [ -f "$TOUCH_MARK" ] || return 0
    _tr_n=0
    if [ -s "$TOUCH_BAK" ]; then
        while IFS='|' read -r _tid _old; do
            [ -n "$_tid" ] || continue
            [ -d "/proc/$_tid" ] || continue
            renice -n "$_old" -p "$_tid" >/dev/null 2>&1 && _tr_n=$((_tr_n + 1))
        done < "$TOUCH_BAK"
    fi
    : > "$TOUCH_BAK" 2>/dev/null
    rm -f "$TOUCH_MARK" 2>/dev/null
    [ "$_tr_n" -gt 0 ] && log_info "触控线程优先级已还原：$_tr_n 个线程"
    return 0
}

# 诊断用：打印 inputflinger 三个线程的当前 nice（验证是否真的提权成功）
touch_status() {
    _ts_p=$(pidof -s inputflinger 2>/dev/null)
    if [ -z "$_ts_p" ]; then
        echo "  inputflinger 进程未找到（Android 12+ 才有独立进程；"
        echo "  更老的版本里这些线程跑在 system_server 内，本开关不适用）"
        return 0
    fi
    echo "  inputflinger pid=$_ts_p  开关 TOUCH_THREAD_BOOST=$TOUCH_THREAD_BOOST"
    echo "  已记账线程: $(grep -c . "$TOUCH_BAK" 2>/dev/null) 个"
    for _td in "/proc/$_ts_p"/task/*; do
        _tid=${_td##*/}
        case "$_tid" in ''|*[!0-9]*) continue ;; esac
        _c=$(cat "$_td/comm" 2>/dev/null)
        case "$_c" in InputReader|InputDispatcher|InputClassifier) ;; *) continue ;; esac
        printf '    %-16s tid=%-7s nice=%s\n' "$_c" "$_tid" "$(tb_nice_of "$_tid")"
    done
}

# ── 等用户数据解锁（比 sys.boot_completed 更靠后，服务才就绪）────
# v2.8.13 省电：原来是死板的 sleep 1 —— 开机阶段最多 300 次唤醒（每次一个
# fork），而用户数据解锁发生在开机后十几秒到几分钟不等，前几秒的 1s 轮询
# 纯属空转。改成退避：1→2→3→4→5s 后保持 5s，总次数从 300 降到 ~90。
# 判定语义不变（仍是「目录出现」或「总等待超 300s」两种出口）。
wait_until_login() {
    _i=0; _s=1
    until [ -d /data/data/android ] || [ "$_i" -gt 300 ]; do
        sleep "$_s"
        _i=$((_i + _s))
        [ "$_s" -lt 5 ] && _s=$((_s + 1))
    done
}

# ── OPPO HORAE 系统服务的 testmode ────────────────────────────
oppo_horae_testmode() {
    [ "$HORAE_TESTMODE" = "1" ] || return 0
    command -v dumpsys >/dev/null 2>&1 || return 0
    dumpsys horae testmode >/dev/null 2>&1
}

# ── 校验欺骗是否真的生效 ──────────────────────────────────────
#  v2.8.5 修复：原实现必然误判失败，有三个独立缺陷 ——
#    1) **期望值来源错位**：拿 SHELL_PROC_T（/proc/shell-temp 的值）当期望值，
#       但 emul_temp 欺骗写的是 thermal_zone（皮肤类用 SKIN_T），而
#       /proc/shell-temp 只在 OPPO_SHELL_TEMP=1 时才写（默认 0，从未写过）
#       → 比对的期望值本身就是错的
#    2) **行首匹配过严**：grep '^Temp:' 要求行首，厂商输出常带缩进或前缀
#    3) **小数位假设**：用 %.2f 固定两位，'Temp:29.5' / 'Temp:29500' 都会判失败
#
#  现在：以模块自身记账 SPOOF_LIST 为事实来源（与 v2.8.2 判定原则一致），
#  dumpsys horae 只作辅助参考，且格式兼容；失败时把原因写进日志。
verify_spoof() {
    # ① 主判据：记账清单里有记录 = 欺骗已应用（写入时逐条记的，不依赖回读）
    if [ -s "$SPOOF_LIST" ]; then
        return 0
    fi
    # ② 记账为空：可能是没应用，也可能是记账丢失 → 交由日志说明
    return 1
}

# 诊断用：把 horae 的实际输出与期望值一并记录，便于定位「为什么没生效」。
# 只在 verify_and_recover 里调用一次，不进主循环。
verify_spoof_detail() {
    _vd_out=$(dumpsys horae 2>/dev/null | grep -i 'temp' | head -n 3)
    if [ -z "$_vd_out" ]; then
        log_debug "  校验详情: dumpsys horae 无 Temp 相关输出（该 ROM 可能不提供此字段）"
    else
        log_debug "  校验详情: horae 读到 [$(echo "$_vd_out" | tr '\n' ' ')]"
    fi
    log_debug "  期望: 皮肤温感被欺骗为 ${SKIN_T} 毫摄氏度"
    if [ "$OPPO_SHELL_TEMP" != "1" ]; then
        log_debug "  提示: OPPO_SHELL_TEMP=0，/proc/shell-temp 未写入（该路径不参与校验）"
    fi
    log_debug "  记账: $(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ') 条记录"
}

# ── 属性写入（带原值备份，可还原）──────────────────────────────
# v2.8.4：同 sysfs_set，改用 awk 行首字面量比较（属性名含 '.'，
# 例如 persist.sys.orms.name，正则 '.' 会匹配任意字符而误判已备份）。
prop_set() {
    _k="$1"; _v="$2"
    awk -v k="$_k=" 'index($0,k)==1 { f=1 } END { exit !f }' "$PROP_BAK" 2>/dev/null || \
        echo "$_k=$(getprop "$_k" 2>/dev/null)" >> "$PROP_BAK" 2>/dev/null
    setprop "$_k" "$_v" 2>/dev/null
    command -v resetprop >/dev/null 2>&1 && resetprop "$_k" "$_v" 2>/dev/null
}

restore_props() {
    [ -f "$PROP_BAK" ] || return 0
    while IFS='=' read -r _k _v; do
        [ -n "$_k" ] && setprop "$_k" "$_v" 2>/dev/null
    done < "$PROP_BAK"
    : > "$PROP_BAK"
    log_info "属性已还原"
}

# ── OPPO ORMS（资源/温控管理）停用 ────────────────────────────
orms_off() {
    [ "$DISABLE_ORMS" = "1" ] || return 0
    setprop ctl.stop vendor.oplus.ormsHalService-aidl-default 2>/dev/null
    prop_set persist.sys.orms.name ""
}

orms_on() {
    restore_props
    setprop ctl.start vendor.oplus.ormsHalService-aidl-default 2>/dev/null
}

# ── 挂载安装时生成的配置改写（bind mount，可用开关控制）─────────
#    SKIP_MOUNT=1 时跳过（post-fs-data 早期阶段调用 apply_state 用）
#    $1 = "$MODDIR/patched/thermal" 或 "$MODDIR/patched/extra"
mount_set() {
    _root="$1"
    [ -d "$_root" ] || return 0
    find "$_root" -type f 2>/dev/null | while IFS= read -r _src; do
        _dst="${_src#$_root}"
        [ -f "$_dst" ] || continue
        # 已挂载则只补记录，不重复叠加。
        # v2.8.4：用 awk 精确比较挂载点字段（$2），替代 grep -q " $_dst "。
        # 原因：grep 把 $_dst 当正则，路径里的 '.' 会匹配任意字符 ——
        # /a/b.xml 会被已挂载的 /a/bXxml 误判为「已挂载」而跳过 bind，
        # 导致该配置静默不生效。awk 做的是字符串相等比较。
        if awk -v d="$_dst" '$2==d { found=1 } END { exit !found }' /proc/mounts 2>/dev/null; then
            grep -qxF "$_dst" "$MOUNT_LIST" 2>/dev/null || echo "$_dst" >> "$MOUNT_LIST"
            continue
        fi
        mount --bind "$_src" "$_dst" 2>/dev/null || continue
        echo "$_dst" >> "$MOUNT_LIST"
        log_debug "mount: $_dst"
    done
}

# v2.8.13 省电：判断记账里的挂载点是否全都还挂着（一次 awk 替代逐文件 awk）。
# 返回 0 = 完整，1 = 有缺失（或从未挂载），调用方据此决定要不要跑完整流程。
_mounts_intact() {
    [ -s "$MOUNT_LIST" ] || return 1
    # 一条 awk 吃两个文件：先登记记账里的挂载点，再拿 /proc/mounts 的第二列销账，
    # 最后看有没有销不掉的。用标量 n 计数而不是 length(array) —— 后者在部分
    # busybox awk 上不支持。
    awk 'NR==FNR { m[$0]=1; n++; next }
         ($2 in m) { delete m[$2]; n-- }
         END { exit (n ? 1 : 0) }' "$MOUNT_LIST" /proc/mounts 2>/dev/null
}

mount_config_overlays() {
    if [ "${SKIP_MOUNT:-0}" = "1" ]; then
        log_info "早期阶段跳过配置挂载 (SKIP_MOUNT=1)"
        return 0
    fi
    # v2.8.13 省电：原实现每次都 find 整个 patched/ 目录，再对**每个文件** fork
    # 一次 awk 去扫 /proc/mounts（GT8 上 ≈20 个文件 → 20+ 次 fork 加 1 次 find）。
    # 但 bind mount 一旦建立，在本进程存活期间不会自己消失，绝大多数轮次这一趟
    # 是纯空转。先整体校验一遍（1 次 awk）：全在就跳过，缺一个才走原路径补挂。
    # 语义不变 —— 补挂的判断依据与原来逐文件判断完全一致，只是合并成一次。
    if _mounts_intact; then
        return 0
    fi
    : > "$MOUNT_LIST" 2>/dev/null
    [ "$PATCH_THERMAL" = "1" ] && mount_set "$MODDIR/patched/thermal"
    [ "$PATCH_EXTRA"   = "1" ] && mount_set "$MODDIR/patched/extra"
    log_info "配置改写挂载完成 (thermal=$PATCH_THERMAL extra=$PATCH_EXTRA)"
}

unmount_config_overlays() {
    [ -f "$MOUNT_LIST" ] || return 0
    while IFS= read -r _dst; do
        [ -n "$_dst" ] && umount "$_dst" 2>/dev/null
    done < "$MOUNT_LIST"
    : > "$MOUNT_LIST"
    log_info "配置改写已卸载"
}

# ── 停用 thermal 相关 init 服务（兜底手段，默认关闭）────────────
# ── v2.12.0：按进程名取 PID（跨 ps 实现的正确写法）────────────────
# 原实现直接 `ps -A | awk '$NF == n { print $2 }'`，把「PID 在第 2 列」当成事实 ——
# 那是 toybox ps 的列序；busybox ps 的列序是 `PID USER TIME COMMAND`（PID 在第 1 列），
# 于是 $2 拿到 USER 名，kill 收到非数字参数静默报错 → STOP_SERVICES 对 perf 守护
# 进程完全失效且无任何提示（不误杀，属功能降级）。
# 现在两级：① 优先 pidof（toybox/busybox 语义一致，无列序假设）；
#           ② 退回 ps 时**按表头找 PID 列**，不硬编码列号。
pid_of_name() {
    _pn="$1"
    [ -n "$_pn" ] || return 0
    _po=$(pidof "$_pn" 2>/dev/null)
    if [ -n "$_po" ]; then printf '%s' "$_po"; return 0; fi
    ps -A 2>/dev/null | awk -v n="$_pn" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "PID") c = i; next }
        c && $NF == n { printf "%s ", $c }'
    return 0
}

stop_thermal_services() {
    for _s in $(getprop | sed -n 's/.*\[init\.svc\.\([^]]*\)\].*/\1/p' | grep -i thermal | sort -u); do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    for _s in thermal-engine thermal-engine-v2 thermal thermald \
              vendor.thermal-engine vendor.thermal vendor.thermald \
              vendor.thermal-hal-2-0 thermal-hal-2-0 vendor.thermal-hal-1-1 \
              vendor.thermal-hal-aidl thermal-hal-aidl vendor.thermal-hal-3-0 \
              vendor.thermal_service vendor.thermalserviced \
              mi_thermald vendor.oplus_thermald oplus_thermald vendor.oppo_thermal ; do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    # realme/OPPO 的 perf/调度守护进程（GT8 实机 `ps -A` 确认，v2.9）：
    #   perfservice / vendor-oplus-hardware-performance-V1-service / oplus_sched 会
    #   独立把大核(perf 簇) scaling_max_freq 压到最低档（960MHz），且读的是自有温度
    #   估算、不走 emul_temp 欺骗路径 —— 不显式停掉，日用限频会被实时抢回。
    #   逐个 ctl.stop，名字对不上/不存在的服务静默失败，无副作用。
    for _s in perfservice vendor.perfservice vendor.perfd perfd \
              perf2-hal-1-0 vendor.qti.hardware.perf2-hal-service \
              vendor-oplus-hardware-performance-V1-service \
              oplus_sched oplus_sched_rename \
              vendor.adpf vendor.thermal-mitigation thermal-mitigation ; do
        setprop ctl.stop "$_s" 2>/dev/null
    done
    # v2.9（versionCode 53）：上面这些 perf/调度守护进程里，perfservice 与
    #   vendor-oplus-hardware-performance-V1-service、oplus_sched 是 init 用 `exec`
    #   直接拉起的（没有 init.svc 属性），`ctl.stop` 会报 "Unable to stop service"
    #   且完全不生效 —— 必须按进程名 kill。ps -A 显示完整进程名（不受 15 字符
    #   comm 截断限制，GT8 实机确认），awk 精确匹配末字段、取 PID 字段 kill。
    for _kn in perfservice vendor-oplus-hardware-performance-V1-service \
               oplus_sched oplus_sched_rename \
               vendor.qti.hardware.perf2-hal-service ; do
        # v2.12.0：改走 pid_of_name（pidof 优先 + ps 按表头定列）——
        # 原实现硬取 $2，在 busybox ps 上拿到的是 USER 名，kill 静默失效。
        _kpids=$(pid_of_name "$_kn")
        [ -n "$_kpids" ] && kill -9 $_kpids 2>/dev/null
    done
}

# ── 归零 cooling_device + 解锁频率 ────────────────────────────
#    ⚠ v2.3 起 cooling_device 归零默认关闭（UNLOCK_CDEV=0）：
#      强制把显示/背光类冷却节点写成 0 会把屏幕亮度压到最低
#      （2026-10-03 实机反馈：亮度锁最低，手动调亮亮一下又被压回去）
#      欺骗生效时内核不会抬升 cur_state，归零属于冗余且有害的"霰弹"手段
DISPLAY_CDEV_PATTERN="*display* *disp* *bright* *backlight* *lcd* *oled* *panel* *screen* *bl-*"
is_display_cdev() {
    _t=""
    read -r _t < "${1%/*}/type" 2>/dev/null
    [ -z "$_t" ] && _t="${1%/*}"
    for _p in $DISPLAY_CDEV_PATTERN; do
        case "$_t" in $_p) return 0 ;; esac
    done
    return 1
}

# 把曾被动过的 cooling_device 还原回原始值（升级到 UNLOCK_CDEV=0 时执行一次）
restore_cdev_once() {
    [ "$UNLOCK_CDEV" = "1" ] && return 0
    [ -f "$PERSIST_DIR/.cdev_restored" ] && return 0
    [ -f "$SYSFS_BAK" ] || { : > "$PERSIST_DIR/.cdev_restored"; return 0; }
    while IFS='=' read -r _p _v; do
        case "$_p" in
            */cooling_device*/cur_state)
                [ -e "$_p" ] && echo "$_v" > "$_p" 2>/dev/null && \
                    log_debug "还原冷却节点: $_p=$_v" ;;
        esac
    done < "$SYSFS_BAK"
    grep -v '/cooling_device.*/cur_state=' "$SYSFS_BAK" > "$SYSFS_BAK.tmp" 2>/dev/null
    mv -f "$SYSFS_BAK.tmp" "$SYSFS_BAK" 2>/dev/null
    : > "$PERSIST_DIR/.cdev_restored"
    log_info "cooling_device 已全部还原（UNLOCK_CDEV=0）"
}

# ── GPU devfreq 上限压制（unlock_perf 与 reapply_perf 共用）──────
# v2.9.2 优化：原先这段「遍历 GPU 节点 → 选档 → 写 max_freq」在 unlock_perf 与
# reapply_perf 里各写了一遍，两份实现要同步维护、极易改漏一边。抽成公共函数，
# 语义完全不变（unlock_perf 走 sysfs_set 带备份；reapply_perf 走裸写 + 值相同
# 跳过，因为原值早已备份过）。
#   $1 = 写值方式：bak=sysfs_set（带备份）/ raw=echo（值相同则跳过）
gpu_devfreq_cap() {
    [ "$UNLOCK_GPU" = "1" ] || return 0
    for _gd in /sys/class/kgsl/kgsl-3d0/devfreq /sys/class/devfreq/*kgsl* \
               /sys/class/devfreq/*gpu*; do
        [ -f "$_gd/available_frequencies" ] || continue
        # 纯 shell 选「≤ GPU_MAX_CLK 的最大档」，默认 INT_MAX 时等价于取最大值
        # （满血），设甜点值则自动封顶。零 fork。
        gpu_cap_target_into "$_gd/available_frequencies"
        [ -n "$_GCAP" ] || continue
        if [ "${1:-bak}" = "raw" ]; then
            _gcur=""
            read -r _gcur < "$_gd/max_freq" 2>/dev/null
            [ "$_gcur" = "$_GCAP" ] && continue
            echo "$_GCAP" > "$_gd/max_freq" 2>/dev/null
        else
            sysfs_set "$_gd/max_freq" "$_GCAP"
        fi
    done
    return 0
}

unlock_perf() {
    [ "$UNLOCK_FREQ" = "1" ] || return 0
    unlock_gpu
    for _cp in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -d "$_cp" ] || continue
        # v2.8.13 省电：read 内建替代两次 cat（8 核 = 16 次 fork → 0）
        _mx=""; read -r _mx < "$_cp/cpuinfo_max_freq" 2>/dev/null
        _mn=""; read -r _mn < "$_cp/cpuinfo_min_freq" 2>/dev/null
        [ -n "$_mx" ] && sysfs_set "$_cp/scaling_max_freq" "$_mx"
        [ -n "$_mn" ] && sysfs_set "$_cp/scaling_min_freq" "$_mn"
    done
    gpu_devfreq_cap bak
    # cooling_device 归零：默认关闭，且永远跳过显示/背光类节点
    [ "$UNLOCK_CDEV" = "1" ] || { restore_cdev_once; return 0; }
    for _c in /sys/class/thermal/cooling_device*; do
        [ -e "$_c/cur_state" ] || continue
        if [ "$DISPLAY_PROTECT" = "1" ] && is_display_cdev "$_c/cur_state"; then
            log_debug "跳过显示类冷却节点: $_c"
            continue
        fi
        sysfs_set "$_c/cur_state" 0
    done
}

# 内核 thermal core 会周期性写回，需要持续压制
reapply_perf() {
    [ "$UNLOCK_FREQ" = "1" ] || return 0
    [ "$UNLOCK_CDEV" = "1" ] && for _c in /sys/class/thermal/cooling_device*/cur_state; do
        [ -e "$_c" ] || continue
        if [ "$DISPLAY_PROTECT" = "1" ] && is_display_cdev "$_c"; then
            continue
        fi
        echo 0 > "$_c" 2>/dev/null
    done
    # v2.8.12 性能：原实现每个 CPU 调一次 cat + 一次 dirname（8 核 = 16 次 fork），
    # 而且**无条件重写** scaling_max_freq —— 值本来就对的时候这一写毫无意义。
    # 现改为：read 内建读节点（零 fork）、${_f%/*} 取目录（零 fork）、值相同直接跳过写。
    for _f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [ -e "$_f" ] || continue
        _mx=""
        read -r _mx < "${_f%/*}/cpuinfo_max_freq" 2>/dev/null
        [ -n "$_mx" ] || continue
        _cur=""
        read -r _cur < "$_f" 2>/dev/null
        [ "$_cur" = "$_mx" ] && continue
        echo "$_mx" > "$_f" 2>/dev/null
    done
    # v2.8.13 修复（P1）：补回 scaling_min_freq 的周期压制。v2.8.12 靠 30s 一次
    # unlock_perf 写 min_freq，v2.8.13 拆维护后这一项被 reapply_perf 漏掉了 ——
    # 后果是 perf 服务抬高 min_freq 后不再被拉回（空闲时也更费电）。零 fork。
    for _f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
        [ -e "$_f" ] || continue
        _mn=""
        read -r _mn < "${_f%/*}/cpuinfo_min_freq" 2>/dev/null
        [ -n "$_mn" ] || continue
        _cur=""
        read -r _cur < "$_f" 2>/dev/null
        [ "$_cur" = "$_mn" ] && continue
        echo "$_mn" > "$_f" 2>/dev/null
    done
    # v2.8.13 修复（P1）：补回 GPU devfreq max_freq 的周期压制。这是关键 ——
    # 内核 devfreq governor 发热降频后，v2.8.12 靠 30s unlock_perf 拉回上限，
    # v2.8.13 拆维护后不拉了，GPU 降频不再恢复。零 fork；GPU_MAX_CLK 甜点值同样生效。
    # v2.9.2：与 unlock_perf 共用 gpu_devfreq_cap，消掉重复实现。
    gpu_devfreq_cap raw
}

# ── 场景检测 ──────────────────────────────────────────────────
get_charging_into() {
    # v2.8.12 性能：原实现每轮 cat 遍历所有 power_supply 节点（GT8 上 5~8 个）= 5~8 次 fork。
    # read 是 shell 内建命令，重定向读第一行即可，零 fork。
    # v2.8.13：再去掉 `echo` —— 调用处 `$(get_charging)` 的命令替换本身就是要
    # fork 一个子 shell 的，一天 17280 次。改为写全局变量 _CHG，echo 版留作兼容。
    _CHG=0
    for _p in /sys/class/power_supply/*/status; do
        [ -f "$_p" ] || continue
        _st=""
        read -r _st < "$_p" 2>/dev/null
        case "$_st" in
            Charging|Full) _CHG=1; return 0 ;;
        esac
    done
    return 0
}
get_charging() { get_charging_into; echo "$_CHG"; }

get_focus_app() {
    # v2.8.12 性能：原来只匹配 'topResumedActivity='，而不同 Android 版本的字段名不同
    # （还有 mResumedActivity / ResumedActivity / mFocusedApp 几种写法）。一旦本机不是
    # topResumedActivity，第一次必然落空 → 每轮跑**两次**重型 dumpsys。
    # 现在一次 dumpsys 匹配全部常见写名；真要全落空，行为与原来完全一致。
    _line=$(dumpsys activity activities 2>/dev/null | \
            grep -m1 -E 'topResumedActivity=|mResumedActivity=|ResumedActivity|mFocusedApp=')
    if [ -z "$_line" ]; then
        _line=$(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=')
    fi
    [ -z "$_line" ] && { echo ""; return; }
    echo "$_line" | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+/' \
        | head -n 1 | sed 's|/$||'
}

is_in_list() {
    _list="$1"; _app="$2"
    [ -r "$_list" ] || return 1
    [ -z "$_app" ] && return 1
    awk -v app="$_app" -F '#' '{
        gsub(/^[ \t\r]+|[ \t\r]+$/, "", $1)
        if ($1 == app) { found=1; exit }
    } END { exit (found ? 0 : 1) }' "$_list"
}

# ── 决策：是否需要移除温控 ────────────────────────────────────
#    返回 1 = 移除（应用欺骗），0 = 保护（撤销欺骗）
#    $1 = reload（默认 1）：调用前若尚未 load_conf 才需要；传 0 表示
#    「调用方刚刚已 load_conf 过」，跳过重复加载。
#    v2.8.4：此前这里无条件 load_conf，而 service.sh 主循环在调用前已
#    load_conf 一次 → 每 5 秒多付一次全量配置解析（约 20 次 conf_get）。
# v2.8.12 新增：判断列表文件里是否有「有效条目」（非空、非纯注释）。
# 纯 shell 扫描，零 fork（列表只有十几行）。
_has_effective() {
    [ -s "$1" ] || return 1
    # `|| [ -n ]`：列表只有一行且无尾换行时，纯 while read 会读不到。
    while IFS= read -r _he_ln || [ -n "$_he_ln" ]; do
        # 先剥前导空白再判注释 —— 否则「缩进过的注释行」（如 "   # com.foo"）
        # 会被当成有效条目，导致 dumpsys 白跑（实测过）。
        _he_t=$_he_ln
        while :; do
            case "$_he_t" in
                ' '*|'	'*) _he_t=${_he_t#?} ;;
                *) break ;;
            esac
        done
        case "$_he_t" in ''|'#'*) continue ;; esac
        return 0
    done < "$1"
    return 1
}

# v2.8.13 省电：两个列表文件几乎从不变化，没必要每 5 秒各重扫一遍（纯 shell
# 但仍是逐行字符串处理，一天 17280×2 次）。缓存机制与 load_conf 一致：
# mtime 变才重扫 + CONF_FORCE_TICKS 强制兜底，全部零 fork。
_LIST_VALID=0
_LIST_TICK=0
_HE_PROT=0
_HE_GAME=0
_he_refresh() {
    _he_need=0
    if [ "$_LIST_VALID" = "1" ]; then
        _LIST_TICK=$((_LIST_TICK + 1))
        [ "$PROTECT_LIST" -nt "$LIST_STAMP" ] && _he_need=1
        [ "$GAME_LIST"    -nt "$LIST_STAMP" ] && _he_need=1
        if [ "${_LIST_TICK:-0}" -ge "${CONF_FORCE_TICKS:-12}" ] 2>/dev/null; then
            _he_need=1; _LIST_TICK=0
        fi
    else
        _he_need=1; _LIST_TICK=0
    fi
    [ "$_he_need" = "1" ] || return 0
    if _has_effective "$PROTECT_LIST"; then _HE_PROT=1; else _HE_PROT=0; fi
    if _has_effective "$GAME_LIST";   then _HE_GAME=1; else _HE_GAME=0; fi
    [ "$CONF_PERSISTENT" = "1" ] && : > "$LIST_STAMP" 2>/dev/null
    _LIST_VALID=1
    return 0
}

decide_state_into() {
    [ "${1:-1}" = "1" ] && load_conf
    if [ "$MODE" = "off" ];    then DECIDE_RESULT=0; return 0; fi
    # v2.12.0：温度保险丝冷却期内一律返回「保护」——
    # 否则 5 秒检测层会立刻把刚被保险丝撤掉的欺骗重新打开，来回抖动。
    if [ "${_FUSE_TICKS:-0}" -gt 0 ] 2>/dev/null; then DECIDE_RESULT=0; return 0; fi
    if [ "$MODE" = "always" ]; then DECIDE_RESULT=1; return 0; fi

    get_charging_into
    if [ "$_CHG" = "1" ]; then DECIDE_RESULT=0; return 0; fi

    # v2.8.12 性能：只有「真的可能命中」时才去查前台应用。
    # 原实现无条件调用 get_focus_app —— 而它跑的是 dumpsys activity activities，
    # 一个输出数百 KB 的重型 Binder 调用，每 5 秒一次（一天 1.7 万次）。
    # 默认配置下 protect_list.conf 全是注释、GAME_PROTECT=0，查出来的包名根本没人用。
    # 加这道闸后，「没配保护/游戏列表」的用户彻底不再触发 dumpsys。
    _he_refresh
    if [ "$_HE_PROT" = "1" ] || { [ "$GAME_PROTECT" = "1" ] && [ "$_HE_GAME" = "1" ]; }; then
        _app=$(get_focus_app)
        if [ -n "$_app" ]; then
            if is_in_list "$PROTECT_LIST" "$_app"; then DECIDE_RESULT=0; return 0; fi
            if [ "$GAME_PROTECT" = "1" ] && is_in_list "$GAME_LIST" "$_app"; then
                DECIDE_RESULT=0; return 0
            fi
        fi
    fi
    DECIDE_RESULT=1
    return 0
}

decide_state() {
    # 保留原「打印结果」的接口；主循环请用 decide_state_into（零 fork）
    decide_state_into "${1:-1}"
    echo "$DECIDE_RESULT"
}

# ── 应用 / 撤销主逻辑 ─────────────────────────────────────────
apply_state() {
    _want="$1"
    # v2.8.13 省电：read 内建替代 `$(cat)`（每次调用省一个子 shell）
    _cur=""
    read -r _cur < "$STATE_FILE" 2>/dev/null

    if [ "$_want" = "1" ]; then
        [ "$STOP_SERVICES" = "1" ] && stop_thermal_services
        orms_off
        mount_config_overlays
        unlock_perf
        oppo_horae_testmode
        touch_boost
        touch_thread_boost
        apply_spoof > /dev/null
        [ "$_cur" = "on" ] || log_info "→ 温控已移除 (mode=$MODE)"
        echo "on" > "$STATE_FILE"
    else
        restore_spoof > /dev/null
        unmount_config_overlays
        restore_sysfs
        # v2.8.8：温控保护期间也把输入线程优先级还原（提权与去温控同属「性能模式」）
        touch_thread_restore
        rm -f "$PERSIST_DIR/.cdev_restored"
        orms_on
        [ "$_cur" = "off" ] || log_info "→ 温控已恢复 (mode=$MODE)"
        echo "off" > "$STATE_FILE"
    fi
}

# ── v2.8.13 省电：状态没变时的「轻维护」 ─────────────────────────
# 原实现每 30s 调一次**完整** apply_state 1，把挂载校验、全量频解锁、ORMS、
# 触控提权、83 个温感重放全套跑一遍。状态没变时，其中大部分是纯空转 ——
# 挂载还在、备份早记过、优先级也没丢。
# 这里只保留「确实可能被系统/其它进程写回、需要周期性压制」的部分：
#   · apply_spoof     内核或其它模块可能清掉 emul_temp → 必须重放
#   · reapply_perf    内核 thermal core 会周期写回 scaling_max_freq → 需要压制
#   · touch_boost / touch_thread_boost   触控服务重启后 pid 变了要补提权
#   · stop_thermal_services / orms_off   init 可能把服务重新拉起（两者默认关）
#   · mount_config_overlays             带「整体校验」快速路径，挂载丢了才补挂
# 不做的是：unlock_perf 的全量备份式写入、状态文件重写、切换日志 ——
# 状态既然没变，就没有任何新信息可写。
# 所有被跳过的步骤在**状态切换时**仍会由 apply_state 完整执行，行为不缺失。
maintain_state() {
    [ "$UNLOCK_FREQ" = "1" ] && reapply_perf
    # v2.8.13 修复（P2）：apply_spoof 返回写入成功的温感数；全部失败（0）时
    # 记账会被 mv 成空、state 却仍是 on，主循环会以为还在欺骗。记日志并置
    # _SPOOF_FAILED，让 service.sh 缩短下次维护间隔（几秒后重试），
    # 而不是干等 120s。原 v2.8.12 是 30s 重试一次，这里至少保住自愈能力。
    _sp_n=$(apply_spoof 2>/dev/null)
    if [ "$_sp_n" = "0" ]; then
        _SPOOF_FAILED=1
        log_warn "! 重放失败：0 个温感写入成功，提前重试"
    else
        _SPOOF_FAILED=0
    fi
    oppo_horae_testmode
    touch_boost
    touch_thread_boost
    [ "$STOP_SERVICES" = "1" ] && stop_thermal_services
    [ "$DISABLE_ORMS"  = "1" ] && orms_off
    mount_config_overlays
    # v2.12.0：温度保险丝挂在维护周期里（低频、只在欺骗生效时才有意义）
    [ "$FUSE_ENABLE" = "1" ] && fuse_tick
    return 0
}

# ══════════════════════════════════════════════════════════════
#  v2.12.0 · 温度保险丝（FUSE）
#
#  为什么需要：本模块此前唯一的安全网是 SoC 硬件结温保护（Tj），而 always 模式连
#  电池过温保护也一并移除 —— 这是文档反复警告、但**软件层面完全没有兜底**的组合。
#  保险丝补上这一层：定期读关键温感的**真实温度**（不是我们写进去的伪装值），
#  越界就立刻撤销欺骗、回原厂保护，并在冷却期内拒绝重新欺骗。
#
#  设计约束：
#   · 低频 —— 每 MAINT_SECONDS（120s）一轮，只采电池 / SoC / 外壳各一路；
#   · 短暴露 —— 写 emul_temp=0 → 读 temp → 立刻写回伪装值（与 api.sh 的真实温度
#     探测同一手法），并复用 REAL_ZERO_MARK 自愈标记，中途被杀下一轮能恢复；
#   · 判定零 fork —— 冷却用进程内 tick 计数，不读时间、不写状态文件；
#   · 默认保守 —— 电池 45℃ 起跳；三路阈值全 0 即整体关闭。
# ══════════════════════════════════════════════════════════════

_fuse_msleep() {
    _fm="$1"
    case "$_fm" in ''|*[!0-9]*) _fm=80 ;; esac
    [ "$_fm" -lt 1 ] && return 0
    if command -v usleep >/dev/null 2>&1; then
        usleep "$((_fm * 1000))" 2>/dev/null && return 0
    fi
    sleep "0.$(printf '%03d' "$_fm")" 2>/dev/null || sleep 1
    return 0
}

# 单路探测：$1=温感目录 $2=阈值(0=关闭该路) $3=线路名
# 返回 1 = 读到可信真值且超阈值（_FUSE_ROUTE / _FUSE_VAL 已写）；0 = 未触发
_fuse_probe_one() {
    _fp_d="$1"; _fp_th="$2"; _fp_rt="$3"
    case "$_fp_th" in ''|0) return 0 ;; esac
    [ -n "$_fp_d" ] && [ -e "$_fp_d/emul_temp" ] && [ -e "$_fp_d/temp" ] || return 0
    _fp_ty=""; read -r _fp_ty < "$_fp_d/type" 2>/dev/null
    [ -n "$_fp_ty" ] || _fp_ty=${_fp_d##*/}
    zone_target_into "$_fp_ty"; _fp_spoof="$_ZTV"
    # 短暂关闭仿真读真值；写不进去（被第三方加锁等）就跳过本轮
    echo 0 > "$_fp_d/emul_temp" 2>/dev/null || return 0
    echo "$_fp_d|$_fp_spoof" >> "$REAL_ZERO_MARK" 2>/dev/null
    _fuse_msleep "${FUSE_DELAY_MS:-80}"
    _fp_real=""; read -r _fp_real < "$_fp_d/temp" 2>/dev/null
    # 立刻恢复伪装值（缩短暴露窗口）并清掉恢复标记 —— 顺序不能反
    echo "$_fp_spoof" > "$_fp_d/emul_temp" 2>/dev/null
    : > "$REAL_ZERO_MARK" 2>/dev/null
    case "$_fp_real" in ''|*[!0-9-]*) return 0 ;; esac
    [ "$_fp_real" = "$_fp_spoof" ] && return 0     # 读到的仍是伪装值 → 内核未刷新，不可信
    [ "$_fp_real" -gt "$_fp_th" ] 2>/dev/null || return 0
    _FUSE_ROUTE="$_fp_rt"; _FUSE_VAL="$_fp_real"
    return 1
}

# 采一轮：任一路越界返回 1（触发），否则返回 0（未触发）。
# 遍历只挑每路第一个命中项，成本恒定（不随温感数量增长）。
fuse_sample_check() {
    [ "$FUSE_ENABLE" = "1" ] || return 0
    _fsz_batt=""; _fsz_soc=""; _fsz_skin=""
    for _fz in /sys/class/thermal/thermal_zone*; do
        [ -e "$_fz/emul_temp" ] && [ -e "$_fz/temp" ] || continue
        _fty=""; read -r _fty < "$_fz/type" 2>/dev/null
        [ -n "$_fty" ] || continue
        is_blacklisted "$_fty" && continue
        case "$_fty" in
            *batt*|*battery*|*usb*)         [ -z "$_fsz_batt" ] && _fsz_batt=$_fz ;;
            *soc*|*cpu*|*ap*|*gpu*|*tsens*) [ -z "$_fsz_soc" ]  && _fsz_soc=$_fz  ;;
            *skin*|*shell*|*case*|*frame*)  [ -z "$_fsz_skin" ] && _fsz_skin=$_fz ;;
        esac
    done
    _fuse_probe_one "$_fsz_batt" "${FUSE_TEMP_BATT:-45000}" 电池 || return 1
    _fuse_probe_one "$_fsz_soc"  "${FUSE_TEMP_SOC:-80000}" SoC  || return 1
    _fuse_probe_one "$_fsz_skin" "${FUSE_TEMP_SKIN:-46000}" 外壳 || return 1
    return 0
}

# 维护周期调用：冷却递减 → 本轮采样 → 触发动作
fuse_tick() {
    [ "$FUSE_ENABLE" = "1" ] || return 0
    if [ "${_FUSE_TICKS:-0}" -gt 0 ] 2>/dev/null; then
        _FUSE_TICKS=$((_FUSE_TICKS - 1))
        if [ "$_FUSE_TICKS" -le 0 ]; then
            _FUSE_TICKS=0
            log_info "✓ 温度保险丝冷却结束：按 MODE=$MODE 恢复原策略"
        else
            log_debug "温度保险丝冷却中（剩 $_FUSE_TICKS 个维护周期）"
        fi
        return 0
    fi
    # fuse_sample_check 的返回语义：0 = 未触发（继续走），1 = 触发（往下走动作）
    if fuse_sample_check; then
        return 0
    fi
    # ── 触发：撤销欺骗 + 进入冷却 ──
    # 冷却时长按维护周期折算成 tick 数；主循环 decide_state 会因它返回 0，
    # 从而在冷却期内**不会**被 5s 检测层重新打开（否则会来回抖动）。
    _FUSE_TRIPS=$(( ${_FUSE_TRIPS:-0} + 1 ))
    _ct=$(( ${FUSE_COOLDOWN:-120} / ${MAINT_SECONDS:-120} ))
    [ "$_ct" -lt 1 ] && _ct=1
    _FUSE_TICKS=$_ct
    log_warn "⚠ 温度保险丝触发[$_FUSE_ROUTE]：真实温度 $_FUSE_VAL 毫摄氏度超阈值 → 撤销欺骗，${FUSE_COOLDOWN}s 内不恢复"
    echo "[$(date '+%m-%d %H:%M:%S')] $_FUSE_ROUTE=$_FUSE_VAL" >> "$FUSE_LOG" 2>/dev/null
    apply_state 0
    return 0
}

# 诊断用：触发次数（读记录文件行数，零副作用）
fuse_trips() {
    _ft_n=0
    [ -s "$FUSE_LOG" ] && _ft_n=$(wc -l < "$FUSE_LOG" 2>/dev/null | tr -d ' ')
    case "$_ft_n" in ''|*[!0-9]*) _ft_n=0 ;; esac
    printf '%s' "$_ft_n"
}

# ══════════════════════════════════════════════════════════════
#  v2.12.0 · 开机自救（boot token）与安全模式
#
#  连续 BOOT_FAIL_LIMIT 次开机没走到 boot-completed（崩溃 / 卡开机 / 被别的模块
#  搞挂），说明上一轮的配置很可能有问题 —— 此时自动把 MODE 置 off 并把温控还给
#  原厂，保证设备一定能进系统。这是 KernelSU 模块的通用自救惯例。
# ══════════════════════════════════════════════════════════════
boot_token_bump() {
    _bt=0
    [ -f "$BOOT_TOKEN" ] && { read -r _bt < "$BOOT_TOKEN" 2>/dev/null; }
    case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
    _bt=$((_bt + 1))
    echo "$_bt" > "$BOOT_TOKEN" 2>/dev/null
    printf '%s' "$_bt"
}

boot_token_clear() { echo 0 > "$BOOT_TOKEN" 2>/dev/null; return 0; }

# 安全模式标记以「文件非空」为准：进入时写入时间戳，退出时清零内容。
# 刻意不用 rm —— `: >` 是内建重定向（零 fork），也不必依赖外部命令是否可用。
safe_mode_active() { [ -s "$SAFE_MODE_MARK" ]; }

# 进入安全模式：撤销一切改写 + MODE=off + 留标记（供 WebUI/status 展示）。
# 手动（action.sh panic）与自动（boot token 超限）共用这一份实现。
panic_to_safe() {
    apply_state 0 2>/dev/null
    if [ -f "$MODE_CONF" ]; then
        sed -i 's|^MODE=.*|MODE=off|' "$MODE_CONF" 2>/dev/null
    else
        printf 'MODE=off\n' > "$MODE_CONF" 2>/dev/null
    fi
    MODE=off
    date '+%Y-%m-%d %H:%M:%S' > "$SAFE_MODE_MARK" 2>/dev/null
    return 0
}

# 用户手动改回 on/dynamic 时清掉安全模式标记（action.sh set_mode 调用）
# 只清内容不删文件：`: >` 零 fork，且与 safe_mode_active 的「非空」判据严格配套。
safe_mode_exit() {
    : > "$SAFE_MODE_MARK" 2>/dev/null
    return 0
}

# ── v2.12.0：清理 CGI 遗留的临时文件 ──────────────────────────
# api.sh 每请求一个 PID（$$），异常退出（httpd 被杀 / 请求超时）会留下 gt8_*.PID
# 一族文件。只清理本模块前缀且 2 小时以上未修改的，避免误删其他程序的文件。
cleanup_stale_tmp() {
    _ct_dir="${TMPDIR:-/data/local/tmp}"
    [ -d "$_ct_dir" ] || return 0
    find "$_ct_dir" -maxdepth 1 -name 'gt8_*' -mmin +120 -delete 2>/dev/null
    return 0
}

# ── v2.13.0 · 一键体检（doctor）───────────────────────────────
# 纯只读报告，供 action.sh doctor / api.sh --doctor / WebUI「体检」复用。
# 全程不 apply / 不 restore / 不写盘（只读 source 已有函数），零副作用。
# 8 节：设备版本 / 内核能力 / 温感命中 / 欺骗状态 / 冲突 / 配置 / 风险 / 依赖权限。
doctor_report() {
    load_conf 2>/dev/null
    echo "== 1/8 设备与版本 =="
    echo "  机型     : $(getprop ro.product.model 2>/dev/null || echo unknown)"
    echo "  Android  : $(getprop ro.build.version.release 2>/dev/null || echo unknown) (SDK $(getprop ro.build.version.sdk 2>/dev/null || echo ?))"
    echo "  内核     : $(uname -r 2>/dev/null || echo unknown)"
    echo "  模块版本 : $(conf_get "$MODDIR/module.prop" version unknown)"
    _dr_ksu=""
    for _dr_kp in ro.sukisu.version ro.sukisu.version.name ro.kernelsu.version \
                   persist.ksu.version persist.sys.ksu.version \
                   ro.ksu.version persist.sukisu.version; do
        _dr_kv=""; _dr_kv=$(getprop "$_dr_kp" 2>/dev/null)
        [ -n "$_dr_kv" ] && { _dr_ksu="$_dr_kv ($_dr_kp)"; break; }
    done
    if [ -z "$_dr_ksu" ] && [ -f /data/adb/ksu/version ]; then
        read -r _dr_ksu < /data/adb/ksu/version 2>/dev/null
        _dr_ksu="$_dr_ksu (/data/adb/ksu/version)"
    fi
    echo "  Root     : ${_dr_ksu:-(未取到，可忽略)}"

    echo "== 2/8 内核能力 =="
    if spoof_supported; then
        echo "  emul_temp : ✓ 支持"
    else
        echo "  emul_temp : ✗ 不支持 —— 将回退「停服务 + 解频」激进模式，效果与风险都更高"
    fi
    _dr_wz=""
    for _dr_z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_dr_z/emul_temp" ] && { _dr_wz="$_dr_z/emul_temp"; break; }
    done
    if [ -n "$_dr_wz" ]; then
        [ -w "$_dr_wz" ] && echo "  写权限   : ✓ $_dr_wz" || echo "  写权限   : ✗ $_dr_wz 不可写（欺骗无法生效）"
    fi

    echo "== 3/8 温感命中 =="
    _dr_zt=0; _dr_ze=0; _dr_bl=0
    for _dr_z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_dr_z/temp" ] || continue
        _dr_zt=$((_dr_zt + 1))
        _dr_ty=""; read -r _dr_ty < "$_dr_z/type" 2>/dev/null
        [ -e "$_dr_z/emul_temp" ] && _dr_ze=$((_dr_ze + 1))
        is_blacklisted "$_dr_ty" && _dr_bl=$((_dr_bl + 1))
    done
    echo "  温感总数 : $_dr_zt"
    echo "  支持仿真 : $_dr_ze（不支持的 $((_dr_zt - _dr_ze)) 个，欺骗对它们无效）"
    echo "  黑名单   : $_dr_bl 个被排除"

    echo "== 4/8 欺骗状态 =="
    _dr_sc=0
    [ -s "$SPOOF_LIST" ] && _dr_sc=$(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ')
    case "$_dr_sc" in ''|*[!0-9]*) _dr_sc=0 ;; esac
    if [ "$_dr_sc" -gt 0 ]; then
        echo "  记账     : ✓ 已欺骗 $_dr_sc 个温感"
    else
        echo "  记账     : ✗ 空（欺骗未生效，或当前处于保护/安全模式）"
    fi
    _dr_state="unknown"
    [ -s "$STATE_FILE" ] && read -r _dr_state < "$STATE_FILE" 2>/dev/null
    echo "  当前状态 : $_dr_state"
    echo "  充电中   : $(get_charging 2>/dev/null)"

    echo "== 5/8 冲突检测 =="
    _dr_cf=$(detect_conflicts 2>/dev/null)
    if [ -z "$_dr_cf" ]; then
        echo "  ✓ 未检测到其他温控模块"
    else
        print_conflicts "  "
    fi

    echo "== 6/8 配置与保险丝 =="
    echo "  MODE     : $MODE"
    echo "  保险丝   : $([ "$FUSE_ENABLE" = "1" ] && echo "开启（累计触发 $(fuse_trips) 次）" || echo "关闭")"

    echo "== 7/8 安全与风险 =="
    _dr_risk=0
    if [ "$MODE" = "always" ] && [ "$SPOOF_BATT" = "1" ]; then
        echo "  ⚠ always 模式 + 电池欺骗开启：充电过温保护失效，只剩硬件熔断兜底"
        _dr_risk=$((_dr_risk + 1))
    fi
    if [ "$FUSE_ENABLE" != "1" ]; then
        echo "  ⚠ 温度保险丝已关闭：真实温度越界时不会自动回退原厂保护"
        _dr_risk=$((_dr_risk + 1))
    fi
    if safe_mode_active; then
        echo "  ⚠ 安全模式：温控已交还原厂（sh $MODDIR/action.sh dynamic 退出）"
        _dr_risk=$((_dr_risk + 1))
    fi
    [ "$STOP_SERVICES" = "1" ] && echo "  ⚠ STOP_SERVICES=1：性能/省电档位自动调节会失效"
    [ "$_dr_risk" = "0" ] && echo "  ✓ 未发现高风险配置"

    echo "== 8/8 依赖与权限 =="
    echo "  busybox   : $(command -v busybox >/dev/null 2>&1 && echo ✓ || echo '✗ 未找到（httpd 通道不可用）')"
    echo "  httpd     : $(command -v httpd >/dev/null 2>&1 && echo ✓ || { busybox httpd --help >/dev/null 2>&1 && echo '✓ (busybox httpd)' || echo '✗ 不可用'; })"
    echo "  日志文件  : $LOG_FILE"
    echo ""
    echo "（复制以上内容即可用于反馈问题）"
}

# ── 打印各温感当前温度 ────────────────────────────────────────
# v2.8.5：「（欺骗）」标记改用记账 SPOOF_LIST 判定，不再回读 emul_temp ——
# 部分厂商内核回读恒 0（写入却生效），回读判定会让所有温感都不显示欺骗标记。
# ── v2.8.11：读 VRR 亮度字段的安装期基线 ───────────────────────
# 返回 $1 键的基线值；基线文件不存在时返回空（调用方据此选择不报警）。
vrr_baseline_get() {
    [ -f "$VRR_BASE" ] || return 0
    while IFS='=' read -r _bk _bv; do
        [ "$_bk" = "$1" ] && { printf '%s' "$_bv"; return 0; }
    done < "$VRR_BASE"
}

dump_temp() {
    # v2.8.13 优化（诊断路径，非热路径）：原来是 `$(cat|tr|tr)` = 3 fork + 每温感
    # 2 次 `$(cat)` ≈ 170 fork，`action.sh diag` 要跑几百 ms。全部 read 化零 fork，
    # 输出格式不变。CR 剥离用顶部 CR 变量（${var%"$CR"} 去行尾 \r，等价原 tr -d '\r'）。
    _dt_sl=" "
    while IFS= read -r _sl_ln || [ -n "$_sl_ln" ]; do
        [ -n "$_sl_ln" ] && _dt_sl="$_dt_sl${_sl_ln%"$CR"} "
    done < "$SPOOF_LIST" 2>/dev/null
    for _z in /sys/class/thermal/thermal_zone*; do
        [ -e "$_z/temp" ] || continue
        _t="";  read -r _t  < "$_z/temp" 2>/dev/null
        _ty=""; read -r _ty < "$_z/type" 2>/dev/null
        case "$_t" in ''|*[!0-9-]*) continue ;; esac
        if [ "${#_t}" -gt 4 ]; then _d=$((_t / 1000)); else _d="$_t"; fi
        _m=""
        case "$_dt_sl" in *"$_z|"*) _m="（欺骗）" ;; esac
        echo "  ${_ty:-zone}: ${_d}°C$_m"
    done
}

# ── 打印全部冷却设备（诊断亮度问题用）──────────────────────────
dump_cdev() {
    for _c in /sys/class/thermal/cooling_device*; do
        [ -e "$_c/cur_state" ] || continue
        _ty="";  read -r _ty  < "$_c/type"      2>/dev/null
        _cur=""; read -r _cur < "$_c/cur_state" 2>/dev/null
        _max=""; read -r _max < "$_c/max_state" 2>/dev/null
        _skip=""
        is_display_cdev "$_c/cur_state" && _skip=" ⚠显示类(已保护)"
        printf "  %-16s type=%-22s cur=%-4s max=%-4s%s\n" \
            "${_c##*/}" "${_ty:-?}" "$_cur" "$_max" "$_skip"
    done
}
