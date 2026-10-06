#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════
#  场景预设档引擎（v2.11.0）
#
#  ── 为什么单独一个文件 ────────────────────────────────────────
#  调用方有两个：WebUI 后端 api.sh、命令行 action.sh。
#  api.sh 是独立 CGI，**故意不 source functions.sh**（那会带来建目录 / 读
#  getprop / 轮转日志等 source-time 副作用，见 functions.sh 的 TR_SIDE_EFFECTS
#  说明）。所以预设逻辑既不能放进 functions.sh（会被 api.sh 排除），
#  也不该在 api.sh 与 action.sh 里各写一份（那是"两份实现迟早走偏"）。
#  → 独立成文件，两边都 source 这一份。
#
#  ── 三条硬性约束 ──────────────────────────────────────────────
#  1. source 本文件**不产生任何副作用**：不建目录、不写文件、不读 sysfs。
#     只有显式调用 preset_apply 才会写配置。
#  2. 局部覆盖（partial overlay）：一个预设只接管它**声明了**的键；没写的键
#     保持用户当前值不动。所以「排障」档可以只调日志级别而不动运行模式。
#  3. 预设**永不接管 BLACKLIST**（也不接管 SHOW_REAL_TEMP / TOUCH_THREAD_NICE
#     / REPLACE_ENCRYPTED 等）。黑名单与界面偏好属于用户个性化设置，
#     切档不该把它们清掉。白名单见 preset_route_key。
#
#  ── 写值约束 ──────────────────────────────────────────────────
#  预设的值必须是**不含空格**的单 token（供 preset_match 用 " K=V " 串做
#  零 fork 查找）。因此 BLACKLIST 这类多词值天然被排除在外 —— 与约束 3 一致。
#
#  ── 安全 ──────────────────────────────────────────────────────
#  · preset id 只允许 [a-z0-9_-]（**刻意不含大写**），且必须能解析到 .conf。
#    不含大写是为了消除大小写折叠歧义：Windows/NTFS 大小写不敏感（DAILY.conf 会
#    解析到 daily.conf）、ext4 敏感，两者行为不一致；限定小写后两边都确定。
#    （先校验字符集再看文件是否存在，双重拦路径穿越 ../../ 与通配符/注入）。
#  · 每个键必须过白名单，每个值必须过取值校验（枚举/0-1/数值范围），
#    非法值**静默跳过**而不是写进去 —— 宁可少改一项，不可写坏一项。
# ═══════════════════════════════════════════════════════════════

# 幂等：重复 source 不重复初始化
[ -n "${PRESET_ENGINE_READY:-}" ] && return 0
PRESET_ENGINE_READY=1

# v2.13.2（A2）：键的归属/默认值/值域统一到 schema.sh（加键只改那一处）
. "${MODDIR:-/data/adb/modules/realme-gt8-sukisu-thermal-remove}/common/schema.sh" 2>/dev/null

# 路径：优先用调用方已设好的变量（api.sh / functions.sh 都设了 MODE_CONF），
# 缺省时按标准安装路径推导。PRESET_DIR 可由调用方覆盖（测试台用）。
PRESET_MODDIR="${MODDIR:-/data/adb/modules/realme-gt8-sukisu-thermal-remove}"
PRESET_DIR="${PRESET_DIR:-$PRESET_MODDIR/presets}"
PRESET_MODE_CONF="${MODE_CONF:-$PRESET_MODDIR/mode.conf}"
PRESET_SPOOF_CONF="${SPOOF_CONF:-$PRESET_MODDIR/spoof.conf}"

# CR 字符运行时生成（与 functions.sh 同一理由：源码里嵌字面 \r 可能被规范化）
[ -n "${PRESET_CR:-}" ] || PRESET_CR=$(printf '\r')
# TAB：api.sh 用「TAB 分隔」把元数据交给一次 awk 统一转义成 JSON。
# 元数据若自身含 TAB 会撑破该格式，所以在读取处直接拒绝（见 preset_meta_into）。
[ -n "${PRESET_TAB:-}" ] || PRESET_TAB=$(printf '\t')

# 去尾空白 / 尾 CR / 首尾双引号 —— 与 functions.sh 的 _strip 同语义。
# 这里必须自带一份：api.sh 不 source functions.sh，而配置可能被 Windows
# 编辑器存成 CRLF（值尾带 \r 会让所有比较恒假、开关静默失效）。
_pm_strip() {
    _ps="$1"
    while :; do
        _ps_ch=0
        case "$_ps" in *" ") _ps="${_ps% }"; _ps_ch=1 ;; esac
        case "$_ps" in *"	") _ps="${_ps%	}"; _ps_ch=1 ;; esac
        case "$_ps" in *"$PRESET_CR") _ps="${_ps%?}"; _ps_ch=1 ;; esac
        [ "$_ps_ch" = "1" ] || break
    done
    case "$_ps" in '"'*) _ps="${_ps#\"}" ;; esac
    case "$_ps" in *'"') _ps="${_ps%\"}" ;; esac
}

# ── 键白名单：判定某键可写、写到哪份配置 ───────────────────────
# 输出 mode / spoof；不在白名单内返回 1（调用方静默跳过）。
# v2.13.2（A2）：归属查 schema_file、可接管性查 schema_preset_ok（约束 3 的
# BLACKLIST / 界面偏好 / 内部调优键预设不接管），不再在此维护键清单。
preset_route_key() {
    schema_file "$1" || return 1
    schema_preset_ok "$1" || return 1
    printf '%s' "$_SC_FILE"
    return 0
}

# ── 取值校验：枚举 / 0-1 开关 / 数值范围（统一到 schema_valid）──
preset_valid_value() {
    schema_valid "$1" "$2"
}

# ── 内置默认值：统一到 schema_default，与 load_conf 同一份 ─────
# 用途：配置里**缺键**时，模块实际按内置默认值运行；判定"当前是否匹配某档"
# 必须用同一套默认值，否则缺键会被判成"不匹配"。
# 结果写 _PM_DEF（避免 $() 子 shell：preset_match 会调上百次）。
preset_default_of() {
    if schema_default "$1"; then
        _PM_DEF="$_SC_DEF"
    else
        _PM_DEF=""
    fi
    return 0
}

# ── 元数据读取：PRESET_NAME/DESC/ICON/ORDER/TAGS/RISK ──────────
# 结果写 _PM_ID/_PM_NAME/_PM_DESC/_PM_ICON/_PM_ORDER/_PM_TAGS/_PM_RISK。
preset_meta_into() {
    _pm_id="$1"
    _PM_ID="$_pm_id"; _PM_NAME=""; _PM_DESC=""; _PM_ICON="◻"
    _PM_ORDER=500; _PM_TAGS=""; _PM_RISK=safe
    case "$_pm_id" in ''|*[!a-z0-9_-]*) return 1 ;; esac
    _pm_f="$PRESET_DIR/$_pm_id.conf"
    [ -f "$_pm_f" ] || return 1
    while IFS= read -r _pm_ln || [ -n "$_pm_ln" ]; do
        case "$_pm_ln" in ''|'#'*) continue ;; esac
        case "$_pm_ln" in *=*) ;; *) continue ;; esac
        _pm_k=${_pm_ln%%=*}; _pm_v=${_pm_ln#*=}
        _pm_strip "$_pm_v"; _pm_v="$_ps"
        # TAB 会撑破调用方「TAB 分隔 → 一次 awk」的 JSON 组装格式，直接判为非法元数据
        case "$_pm_v" in *"$PRESET_TAB"*) continue ;; esac
        case "$_pm_k" in
            PRESET_NAME)  _PM_NAME=$_pm_v ;;
            PRESET_DESC)  _PM_DESC=$_pm_v ;;
            PRESET_ICON)  _PM_ICON=$_pm_v ;;
            PRESET_TAGS)  _PM_TAGS=$_pm_v ;;
            PRESET_RISK)  _PM_RISK=$_pm_v ;;
            PRESET_ORDER) case "$_pm_v" in ''|*[!0-9]*) ;; *) _PM_ORDER=$_pm_v ;; esac ;;
        esac
    done < "$_pm_f"
    [ -n "$_PM_NAME" ] || _PM_NAME=$_pm_id
    return 0
}

# ── 列出全部预设 id，按 PRESET_ORDER 升序（同序按 id）──────────
preset_ids() {
    [ -d "$PRESET_DIR" ] || return 0
    for _pi_f in "$PRESET_DIR"/*.conf; do
        [ -f "$_pi_f" ] || continue
        _pi_id=${_pi_f##*/}; _pi_id=${_pi_id%.conf}
        case "$_pi_id" in ''|*[!a-z0-9_-]*) continue ;; esac
        preset_meta_into "$_pi_id" || continue
        printf '%s %s\n' "$_PM_ORDER" "$_pi_id"
    done | sort -k1,1n -k2,2 | while IFS=' ' read -r _pi_o _pi_i; do
        [ -n "$_pi_i" ] && printf '%s\n' "$_pi_i"
    done
}

# ── 取一个预设的**已验证**配置行（KEY=VALUE 每行一条）──────────
# 未通过白名单/取值校验的键静默丢弃。id 非法或文件不存在返回 1。
preset_pairs() {
    _pp_id="$1"
    case "$_pp_id" in ''|*[!a-z0-9_-]*) return 1 ;; esac
    _pp_f="$PRESET_DIR/$_pp_id.conf"
    [ -f "$_pp_f" ] || return 1
    _pp_seen=""
    while IFS= read -r _pp_ln || [ -n "$_pp_ln" ]; do
        case "$_pp_ln" in ''|'#'*) continue ;; esac
        case "$_pp_ln" in *=*) ;; *) continue ;; esac
        _pp_k=${_pp_ln%%=*}; _pp_v=${_pp_ln#*=}
        case "$_pp_k" in PRESET_*) continue ;; esac
        case " $_pp_seen " in *" $_pp_k "*) continue ;; esac   # 只认首次出现
        preset_route_key "$_pp_k" >/dev/null 2>&1 || continue
        _pm_strip "$_pp_v"; _pp_v="$_ps"
        preset_valid_value "$_pp_k" "$_pp_v" || continue
        _pp_seen="$_pp_seen $_pp_k"
        printf '%s=%s\n' "$_pp_k" "$_pp_v"
    done < "$_pp_f"
    return 0
}

# ── 写单个键（自包含的极简实现）───────────────────────────────
# 与 api.sh 的 conf_set 同语义：行首字面量判重（不用 grep —— 路径/键里的
# '.' 会被当正则；也不用 grep -F ——它不支持 ^ 锚点会子串误判），
# 替换文本里的 & | \ 先转义再换 | 作定界符。
_pconf_set() {
    _pc_w="$1"; _pc_k="$2"; _pc_v="$3"
    case "$_pc_w" in
        mode)  _pc_f="$PRESET_MODE_CONF" ;;
        spoof) _pc_f="$PRESET_SPOOF_CONF" ;;
        *) return 1 ;;
    esac
    [ -f "$_pc_f" ] || return 1
    _pc_e=$(printf '%s' "$_pc_v" | sed 's/[&|\\]/\\&/g')
    if awk -v k="$_pc_k=" 'index($0,k)==1 { f=1 } END { exit !f }' "$_pc_f" 2>/dev/null; then
        sed -i "s|^$_pc_k=.*|$_pc_k=$_pc_e|" "$_pc_f" 2>/dev/null || return 1
    else
        printf '%s=%s\n' "$_pc_k" "$_pc_v" >> "$_pc_f" 2>/dev/null || return 1
    fi
    return 0
}

# ── 应用预设 ⭐ 唯一会写盘的动作 ───────────────────────────────
# 输出：实际写入成功的 KEY=VALUE 行（供调用方展示"改了哪些"）。
# 返回：至少写入 1 项 → 0；id 非法 / 文件不存在 / 一项都没写成功 → 1。
preset_apply() {
    _pa_id="$1"
    _pa_tmp="${TMPDIR:-/data/local/tmp}/gt8_preset_$$"
    preset_pairs "$_pa_id" > "$_pa_tmp" 2>/dev/null || { rm -f "$_pa_tmp"; return 1; }
    [ -s "$_pa_tmp" ] || { rm -f "$_pa_tmp"; return 1; }
    _pa_n=0
    # 用输入重定向而不是管道 —— 管道会让循环体落在子 shell 里，_pa_n 不回传
    while IFS= read -r _pa_kv || [ -n "$_pa_kv" ]; do
        case "$_pa_kv" in *=*) ;; *) continue ;; esac
        _pa_k=${_pa_kv%%=*}; _pa_v=${_pa_kv#*=}
        _pa_w=$(preset_route_key "$_pa_k")
        if _pconf_set "$_pa_w" "$_pa_k" "$_pa_v"; then
            printf '%s\n' "$_pa_kv"
            _pa_n=$((_pa_n + 1))
        fi
    done < "$_pa_tmp"
    rm -f "$_pa_tmp"
    [ "$_pa_n" -gt 0 ] && return 0
    return 1
}

# ── v2.17.5 / U5：预设导出 —— 把某档的完整 .conf 原样打印 ─────
# 预设本就是纯文本 K=V，天然可分享：导出的片段放到另一台设备的
# presets/ 目录下即可用。id 仍走白名单 + 文件存在双重校验。
preset_export() {
    _px_id="$1"
    case "$_px_id" in ''|*[!a-z0-9_-]*) return 1 ;; esac
    _px_f="$PRESET_DIR/$_px_id.conf"
    [ -f "$_px_f" ] || return 1
    cat "$_px_f"
    return 0
}

# ── v2.17.5 / U5：预设导入 —— 从 stdin 读 K=V 文本，校验后落盘 ──
# 三道闸（复用现有引擎，不另起校验）：
#   ① id 白名单 [a-z0-9_-]，且**拒绝覆盖内置五档**（模块分发，导入用新 id）
#   ② 每行键要么是 PRESET_* 元数据（只认已知字段，值不得含 TAB），
#      要么过 preset_route_key（schema_file + schema_preset_ok → 自动排除
#      BLACKLIST / 个性化键）
#   ③ 每行值过 preset_valid_value（schema_valid 值域）
# 全部合法才落盘（先写临时再 mv，原子替换），任一行非法整体拒绝。
preset_import() {
    _pi_id="$1"
    case "$_pi_id" in ''|*[!a-z0-9_-]*) return 1 ;; esac
    case "$_pi_id" in stock|daily|game|cool|debug) return 2 ;; esac
    _pi_tmp="${TMPDIR:-/data/local/tmp}/gt8_import_$$"
    cat > "$_pi_tmp" 2>/dev/null || return 1
    [ -s "$_pi_tmp" ] || { rm -f "$_pi_tmp" 2>/dev/null; return 1; }
    _pi_keys=0
    while IFS= read -r _pi_ln || [ -n "$_pi_ln" ]; do
        case "$_pi_ln" in ''|'#'*) continue ;; esac
        case "$_pi_ln" in *=*) ;; *) rm -f "$_pi_tmp" 2>/dev/null; return 1 ;; esac
        _pi_k=${_pi_ln%%=*}; _pi_v=${_pi_ln#*=}
        case "$_pi_k" in
            PRESET_NAME|PRESET_DESC|PRESET_ICON|PRESET_TAGS|PRESET_RISK|PRESET_ORDER)
                case "$_pi_v" in *"$PRESET_TAB"*) rm -f "$_pi_tmp" 2>/dev/null; return 1 ;; esac
                case "$_pi_k" in
                    PRESET_ORDER) case "$_pi_v" in ''|*[!0-9]*) rm -f "$_pi_tmp" 2>/dev/null; return 1 ;; esac ;;
                esac
                _pi_keys=$((_pi_keys + 1)) ;;
            PRESET_*)
                rm -f "$_pi_tmp" 2>/dev/null; return 1 ;;   # 未知元数据字段
            *)
                preset_route_key "$_pi_k" >/dev/null 2>&1 || { rm -f "$_pi_tmp" 2>/dev/null; return 1; }
                _pm_strip "$_pi_v"; _pi_v="$_ps"
                preset_valid_value "$_pi_k" "$_pi_v" || { rm -f "$_pi_tmp" 2>/dev/null; return 1; }
                _pi_keys=$((_pi_keys + 1)) ;;
        esac
    done < "$_pi_tmp"
    [ "$_pi_keys" -gt 0 ] || { rm -f "$_pi_tmp" 2>/dev/null; return 1; }
    mv -f "$_pi_tmp" "$PRESET_DIR/$_pi_id.conf" 2>/dev/null || { rm -f "$_pi_tmp" 2>/dev/null; return 1; }
    return 0
}

# ── 只读：把两份配置装进 " K=V K=V " 串（供零 fork 查找）──────
_PMCACHE=""
_PMCACHE_SEEN=""
_pm_cache_load() {
    _PMCACHE=" "; _PMCACHE_SEEN=" "
    for _plc_f in "$PRESET_MODE_CONF" "$PRESET_SPOOF_CONF"; do
        [ -f "$_plc_f" ] || continue
        while IFS= read -r _plc_ln || [ -n "$_plc_ln" ]; do
            case "$_plc_ln" in ''|'#'*) continue ;; esac
            case "$_plc_ln" in *=*) ;; *) continue ;; esac
            _plc_k=${_plc_ln%%=*}; _plc_v=${_plc_ln#*=}
            case "$_PMCACHE_SEEN" in *" $_plc_k "*) continue ;; esac
            _PMCACHE_SEEN="$_PMCACHE_SEEN$_plc_k "
            _pm_strip "$_plc_v"
            _PMCACHE="$_PMCACHE$_plc_k=$_ps "
        done < "$_plc_f"
    done
}
# 从缓存取键值；缺键回落内置默认。结果写 _PM_CUR。
_pm_cache_get() {
    _pg_k="$1"
    _PM_CUR=""
    case "$_PMCACHE" in
        *" $_pg_k="*)
            _pg_r=${_PMCACHE#*" $_pg_k="}
            _PM_CUR=${_pg_r%% *}
            ;;
    esac
    if [ -z "$_PM_CUR" ]; then
        preset_default_of "$_pg_k"
        _PM_CUR="$_PM_DEF"
    fi
    return 0
}

# ── 只读：当前配置与某档的匹配度 ───────────────────────────────
# 用于 WebUI 判定「已应用」与「最接近哪一档（基于 X 改了 N 项）」。
# 无状态：不记录"上次应用了哪个"，全靠比对 —— 用户手改一个开关后
# 匹配数立刻下降，界面自然显示为"自定义"，不会撒谎。
#
# _into 版把结果写进 _PMT_M / _PMT_T（**零 fork**）：api.sh 要为 5 个档各算
# 一次，用 `$(preset_match)` 就是 5 次子 shell；在 fork 昂贵的小内核/旧设备上
# 这种"只为取两个数"的子 shell 是最不划算的开销。
# preset_match 保留 echo 版供命令行 action.sh 使用。
preset_match_into() {
    _pmt_id="$1"
    _PMT_M=0; _PMT_T=0
    _pmt_tmp="${TMPDIR:-/data/local/tmp}/gt8_pmatch_$$"
    preset_pairs "$_pmt_id" > "$_pmt_tmp" 2>/dev/null || { rm -f "$_pmt_tmp"; return 0; }
    _pm_cache_load
    while IFS= read -r _pmt_kv || [ -n "$_pmt_kv" ]; do
        case "$_pmt_kv" in *=*) ;; *) continue ;; esac
        _pmt_k=${_pmt_kv%%=*}; _pmt_v=${_pmt_kv#*=}
        _PMT_T=$((_PMT_T + 1))
        _pm_cache_get "$_pmt_k"
        [ "$_PM_CUR" = "$_pmt_v" ] && _PMT_M=$((_PMT_M + 1))
    done < "$_pmt_tmp"
    rm -f "$_pmt_tmp"
    return 0
}

preset_match() {
    preset_match_into "$1"
    printf '%s %s' "$_PMT_M" "$_PMT_T"
    return 0
}
