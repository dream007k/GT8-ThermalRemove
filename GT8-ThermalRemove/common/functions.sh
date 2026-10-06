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
# 温频历史快照（v2.16.0 F5）：每行 "epoch soc_temp cpu0 cpu6 gpu"，滚动保留 120 条。
# 温度用真实值（_fuse_read_one 采），频率是 scaling/devfreq cur_freq 直读。
HISTORY_LIST="${HISTORY_LIST:-$PERSIST_DIR/history.list}"

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

# v2.15.0：配置路径改为支持环境变量覆盖（${VAR:-默认}）——回归测试在 source
# 本文件之前 export MODE_CONF 等指向影子配置，即可让 preset_apply 等写进影子文件
# 而非真实 mode.conf。真机不 export，行为不变（仍用 $MODDIR 下默认路径）。
MODE_CONF="${MODE_CONF:-$MODDIR/mode.conf}"
SPOOF_CONF="${SPOOF_CONF:-$MODDIR/spoof.conf}"
GAME_LIST="${GAME_LIST:-$MODDIR/game_list.conf}"
PROTECT_LIST="${PROTECT_LIST:-$MODDIR/protect_list.conf}"

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

# ══ v2.14.0（A3）：按功能域拆分，本文件只保留变量定义 + 聚合 source ══
# 子模块清单（按依赖顺序）：
. "$MODDIR/common/log.sh"
. "$MODDIR/common/config.sh"
. "$MODDIR/common/spoof.sh"
. "$MODDIR/common/perf.sh"
. "$MODDIR/common/system.sh"
. "$MODDIR/common/state.sh"
. "$MODDIR/common/fuse.sh"
. "$MODDIR/common/doctor.sh"
. "$MODDIR/common/presets.sh"   # v2.15.0 F4：自动切档需要预设引擎

