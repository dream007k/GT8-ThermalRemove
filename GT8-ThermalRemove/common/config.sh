# GT8 ThermalRemove · common/config.sh
# 配置加载 / conf_get / sysfs 备份还原
# v2.14.0（A3）：从 functions.sh 拆出，由 functions.sh 聚合 source，不单独使用。


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
