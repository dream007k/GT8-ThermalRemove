# GT8 ThermalRemove · common/log.sh
# 日志分级输出（v2.10.0）
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


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
