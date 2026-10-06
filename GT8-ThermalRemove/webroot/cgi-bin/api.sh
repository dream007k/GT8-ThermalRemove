#!/system/bin/sh
# WebUI 后端：同时支持「root 直连（ksu.exec）」与「CGI（busybox httpd）」两种模式
#   sh api.sh --status                       # 读取全部配置与状态
#   sh api.sh --set MODE=always GAME_PROTECT=0
#   sh api.sh --temps                        # 遍历 thermal_zone
#   sh api.sh --log                          # 日志末尾
#   sh api.sh --verify                       # 校验欺骗是否生效
#   sh api.sh --conflicts                    # 检测其他温控模块（v2.8）
#   sh api.sh --diagpack                     # 导出诊断包（v2.10.0）
#   sh api.sh --presets                      # 场景预设档列表 + 当前匹配度（v2.11.0）
#   sh api.sh --preset daily                 # 应用某个场景预设
#   sh api.sh --setlist '*disp* *panel*'     # 写 BLACKLIST（含空格，走专用通道）
# KernelSU/SukiSU 管理器内打开 WebUI 时走 ksu.exec 直连（首选）；
# 浏览器访问 http://127.0.0.1:37654 时走 httpd CGI。
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in /*) ;; *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;; esac
SCRIPT_DIR="${SCRIPT_PATH%/*}"
WEBROOT_DIR="${SCRIPT_DIR%/*}"
MODDIR="${THERMAL_MODDIR:-${WEBROOT_DIR%/*}}"
# 兜底：目录中缺少 common/ 说明推导失败，退回标准安装路径
[ -d "$MODDIR/common" ] || MODDIR=/data/adb/modules/realme-gt8-sukisu-thermal-remove

# v2.11.0：与 STATE_FILE / LOG_FILE 同风格，改用 `${VAR:-default}` ——
# 真机行为完全不变（环境未设时仍指向同一路径），但让行为等价性测试能把这些
# **可写**路径指到临时目录，从而在不起副作用的前提下验证预设应用与黑名单写入。
MODE_CONF="${MODE_CONF:-$MODDIR/mode.conf}"
SPOOF_CONF="${SPOOF_CONF:-$MODDIR/spoof.conf}"
# v2.9.3：改用 `${VAR:-default}` 形式 —— 真机行为完全不变（仍指向同一路径），
# 但让行为等价性测试能把它们指到临时目录，从而真正验证「只读入口不写盘」。
STATE_FILE="${STATE_FILE:-/data/adb/thermal_remove/state}"
LOG_FILE="${LOG_FILE:-/data/adb/thermal_remove/thermal_remove.log}"
LOG_TAG="gt8_thermal_webui"
# 真实温度探测的恢复标记：写 0 前落盘「目录|伪装值」，恢复后清除。
# 若探测进程中途被杀，下次探测会先按它自愈（否则该温感欺骗会一直失效）。
REAL_ZERO_MARK="${REAL_ZERO_MARK:-/data/adb/thermal_remove/.real_zeroed}"
# v2.12.0：温度保险丝的触发记录与安全模式标记（只读展示，可注入便于测试）
FUSE_LOG="${FUSE_LOG:-/data/adb/thermal_remove/fuse.log}"
SAFE_MODE_MARK="${SAFE_MODE_MARK:-/data/adb/thermal_remove/.safe_mode}"
# v2.16.0 F5：温频历史快照（service 维护周期写，WebUI 曲线读，可注入便于测试）
HISTORY_LIST="${HISTORY_LIST:-/data/adb/thermal_remove/history.list}"
# v2.13.2（A2）：配置键唯一事实源（零副作用，可安全 source）
. "$MODDIR/common/schema.sh" 2>/dev/null
# 欺骗记账：apply_spoof 写成功的温感清单（dir|value 每行一条）。
# 判定「是否欺骗中」以它为准 —— 部分厂商内核 emul_temp 回读恒为 0，
# 回读判定会导致「欺骗实际生效但全部被判成未欺骗」，探测也随之被跳过。
SPOOF_LIST="${SPOOF_LIST:-/data/adb/thermal_remove/spoof.list}"
# 温感基目录：仅用于测试注入假 sysfs 树，真机固定 /sys/class/thermal
TZ_BASE="${TZ_BASE:-/sys/class/thermal}"
# 配置改写挂载记账：仅用于测试注入，真机固定 /data/adb/thermal_remove/mounts.list
MOUNT_LIST="${MOUNT_LIST:-/data/adb/thermal_remove/mounts.list}"

json_header() {
    echo "Content-Type: application/json; charset=utf-8"
    echo "Access-Control-Allow-Origin: *"
    echo "Cache-Control: no-store"
    echo "Pragma: no-cache"
    echo ""
}

json_error() { echo "{\"success\":false,\"message\":\"$(_jesc "$1")\"}"; }

# v2.11.2：写操作跨源防护（CSRF）。本 httpd 绑定 127.0.0.1，挡住了远程攻击者，
# 但现代浏览器把 http://127.0.0.1 视为 potentially trustworthy —— 恶意网页可以在
# 用户开着 WebUI 期间对它发 simple request（不触发 preflight），借 ACAO:* 静默改写
# root 级配置（MODE / SPOOF_BATT / 黑名单等）。
# 放行三种正常路径：ksu.exec 直连（根本不走 httpd）、浏览器直接打开本页面后发起的
# 同源 fetch（不带 Origin）、老 WebView（不发 Origin）。只有明确声明了「别的来源」
# 的请求才拒绝 —— Origin 头只有浏览器跨源时才会加，恰好是要拦的那一类。
_cgi_origin_ok() {
    case "${HTTP_ORIGIN:-}${HTTP_REFERER:-}" in
        *127.0.0.1*|*localhost*) return 0 ;;
        "") return 0 ;;
        *) return 1 ;;
    esac
}

# v2.9.3：CR 供「去行尾 \r」用（read 内建替代 tr -d '\r'，避免每次 fork）。
# printf 是 POSIX 内建，启动期算一次即可；本脚本独立于 functions.sh，故自带一份。
CR_API=$(printf '\r')

# JSON 字符串转义：反斜杠与双引号加反斜杠，并剥掉控制字符。
# sed 的替换里 `\\&` = 字面反斜杠 + 被匹配字符（& 是"整个匹配"）。
_jesc() { printf '%s' "$1" | sed -e 's/[\\"]/\\&/g' -e 's/[[:cntrl:]]//g'; }

# 临时文件路径：Android 上 /data/local/tmp 一定存在且可写，优先于不可靠的 TMPDIR
_mktmp() {
    _mk_p="${TMPDIR:-/data/local/tmp}/gt8_$1.$$"
    : > "$_mk_p" 2>/dev/null || _mk_p="/data/local/tmp/gt8_$1.$$"
    : > "$_mk_p" 2>/dev/null || return 1
    printf '%s' "$_mk_p"
}

# 毫秒级等待：usleep 优先（µs 精度），其次支持小数秒的 sleep，
# 都不可用时退化为 1 秒 —— 保证内核有足够时间刷新温感读数
_msleep() {
    _m="$1"
    case "$_m" in ''|*[!0-9]*) _m=80 ;; esac
    [ "$_m" -lt 1 ] && _m=1
    if command -v usleep >/dev/null 2>&1 && usleep "$((_m * 1000))" 2>/dev/null; then
        return 0
    fi
    if sleep "0.$(printf '%03d' "$_m")" 2>/dev/null; then
        return 0
    fi
    sleep 1
}

# v2.8.4：与 common/functions.sh 的 conf_get 保持同一实现（纯 shell 去壳，
# 省掉两次 sed + 一个管道）。此处必须保持自包含 —— 本脚本是独立 CGI，
# 不能 source functions.sh（那会带来建目录 / 读 getprop 等副作用）。
_strip() {
    _sv="$1"
    while :; do
        case "$_sv" in
            *" ") _sv="${_sv% }" ;;
            *"	") _sv="${_sv%	}" ;;
            *) break ;;
        esac
    done
    case "$_sv" in '"'*) _sv="${_sv#\"}" ;; esac
    case "$_sv" in *'"') _sv="${_sv%\"}" ;; esac
}

conf_get() {
    _f="$1"; _k="$2"; _d="$3"
    # v2.16.0 性能：原实现 `sed | head` 每次 2 次 fork —— get_status 26 次 conf_get
    # 就是 52 次 fork，是 WebUI 卡的主因之一。改纯 shell（read 内建 + case 前缀匹配），
    # 零 fork；语义与原来一致（行首 KEY=、取首个、剥行内注释、strip、默认值）。
    _v=""
    while IFS= read -r _cg_ln || [ -n "$_cg_ln" ]; do
        case "$_cg_ln" in
            "$_k"=*) _v=${_cg_ln#*=}; _v=${_v%%#*}; break ;;
        esac
    done < "$_f" 2>/dev/null
    if [ -n "$_v" ]; then
        _strip "$_v"
        _v="$_sv"
    fi
    [ -z "$_v" ] && _v="$_d"
    echo "$_v"
}

conf_set() {
    _f="$1"; _k="$2"; _v="$3"
    [ -f "$_f" ] || return 1
    # v2.8.4：替换文本里的 & 是「整个匹配」、| 是新定界符、\ 是转义符 ——
    # 直接内插进 s/…/…/ 会导致内容错乱（值含 & 时会把整行塞进去）或
    # 直接报错（值含 / 时把它当定界符，保存静默失败）。
    # 这里先转义这三个字符，再改用 | 作定界符。
    _e=$(printf '%s' "$_v" | sed 's/[&|\\]/\\&/g')
    if awk -v k="$_k=" 'index($0,k)==1 { f=1 } END { exit !f }' "$_f" 2>/dev/null; then
        sed -i "s|^$_k=.*|$_k=$_e|" "$_f"
    else
        echo "$_k=$_v" >> "$_f"
    fi
    return 0
}

get_status() {
    _mode=$(conf_get "$MODE_CONF" MODE dynamic)
    _gp=$(conf_get "$MODE_CONF" GAME_PROTECT 0)
    _ss=$(conf_get "$MODE_CONF" STOP_SERVICES 0)
    _uf=$(conf_get "$MODE_CONF" UNLOCK_FREQ 1)
    _pt=$(conf_get "$MODE_CONF" PATCH_THERMAL 1)
    _pe=$(conf_get "$MODE_CONF" PATCH_EXTRA 0)
    _st=$(conf_get "$MODE_CONF" OPPO_SHELL_TEMP 0)
    _og=$(conf_get "$MODE_CONF" OPPO_GAUGE 0)
    _sb=$(conf_get "$SPOOF_CONF" SPOOF_BATT 1)
    _soc=$(conf_get "$SPOOF_CONF" SOC_T 29500)
    # v2.9.3 修复：默认值原为 33000，与 spoof.conf（SKIN_T=29500）和
    # functions.sh 的 load_conf 兜底（29500）不一致 —— 一旦 spoof.conf 里
    # 该键被删/写坏，WebUI 会显示 33.0°C 而模块实际按 29.5°C 欺骗，用户看到的
    # 与实际行为对不上。统一为 29500。
    _skin=$(conf_get "$SPOOF_CONF" SKIN_T 29500)
    _cam=$(conf_get "$SPOOF_CONF" CAM_T 29500)
    _batt=$(conf_get "$SPOOF_CONF" BATT_T 29500)
    _spt=$(conf_get "$SPOOF_CONF" SHELL_PROC_T 29500)
    _ht=$(conf_get "$MODE_CONF" HORAE_TESTMODE 0)
    _or=$(conf_get "$MODE_CONF" DISABLE_ORMS 0)
    _tb=$(conf_get "$MODE_CONF" TOUCH_BOOST 1)
    _ttb=$(conf_get "$MODE_CONF" TOUCH_THREAD_BOOST 0)
    _uc=$(conf_get "$MODE_CONF" UNLOCK_CDEV 0)
    _dp=$(conf_get "$MODE_CONF" DISPLAY_PROTECT 1)
    _re=$(conf_get "$MODE_CONF" REPLACE_ENCRYPTED 0)
    _rt=$(conf_get "$MODE_CONF" SHOW_REAL_TEMP 1)
    _lv=$(conf_get "$MODE_CONF" LOG_LEVEL info)
    # v2.11.0：温感树要按「原始通配符列表」做增删（而不是由树上命中的温感反推），
    # 否则那些当前没有对应温感的规则会在一次屏蔽操作后被静默丢掉。
    _bl=$(conf_get "$SPOOF_CONF" BLACKLIST '')

    _state=$(cat "$STATE_FILE" 2>/dev/null)
    [ -z "$_state" ] && _state="unknown"

    # v2.9.3：版本号由后端读 module.prop 带出，取代前端写死的 FALLBACK_VER
    #（那个常量停在 v2.8.2，HTTP/CGI 通道下徽标会一直显示旧版本，误导排查）。
    _ver=""
    while IFS='=' read -r _vk _vv; do
        [ "$_vk" = "version" ] && { _ver=$_vv; break; }
    done < "$MODDIR/module.prop" 2>/dev/null

    _chg=0
    # v2.9.3：read 是内建命令，替代 `$(cat)` 的每节点一次 fork（GT8 上 5~8 个）。
    # 与 functions.sh 的 get_charging_into 保持同一写法。
    for _p in /sys/class/power_supply/*/status; do
        [ -f "$_p" ] || continue
        _pst=""; read -r _pst < "$_p" 2>/dev/null
        case "$_pst" in Charging|Full) _chg=1; break ;; esac
    done

    _emu=0
    for _z in "$TZ_BASE"/thermal_zone*; do
        [ -e "$_z/emul_temp" ] && { _emu=1; break; }
    done

    # 统计：温感总数 / 欺骗中数量 / 已挂载配置数
    # 欺骗中数量读记账清单（原因见 SPOOF_LIST 说明：emul_temp 回读不可靠）
    _zt=0; _zs=0
    for _z in "$TZ_BASE"/thermal_zone*; do
        [ -e "$_z/temp" ] && _zt=$((_zt + 1))
    done
    _zs=$(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ')
    case "$_zs" in ''|*[!0-9]*) _zs=0 ;; esac
    _mnt=0
    [ -f "$MOUNT_LIST" ] && \
        _mnt=$(wc -l < "$MOUNT_LIST" 2>/dev/null | tr -d ' ')
    case "$_mnt" in ''|*[!0-9]*) _mnt=0 ;; esac

    # v2.12.0：温度保险丝与安全模式（只读展示）
    _fuse_e=$(conf_get "$MODE_CONF" FUSE_ENABLE 1)
    _fuse_n=0
    [ -s "$FUSE_LOG" ] && _fuse_n=$(wc -l < "$FUSE_LOG" 2>/dev/null | tr -d ' ')
    case "$_fuse_n" in ''|*[!0-9]*) _fuse_n=0 ;; esac
    _fuse_last=""
    [ -s "$FUSE_LOG" ] && _fuse_last=$(tail -n 1 "$FUSE_LOG" 2>/dev/null)
    _safe=0; [ -s "$SAFE_MODE_MARK" ] && _safe=1

    echo "{\"success\":true,\"MODE\":\"$_mode\",\"GAME_PROTECT\":\"$_gp\",\"STOP_SERVICES\":\"$_ss\",\"UNLOCK_FREQ\":\"$_uf\",\"PATCH_THERMAL\":\"$_pt\",\"PATCH_EXTRA\":\"$_pe\",\"OPPO_SHELL_TEMP\":\"$_st\",\"OPPO_GAUGE\":\"$_og\",\"HORAE_TESTMODE\":\"$_ht\",\"DISABLE_ORMS\":\"$_or\",\"TOUCH_BOOST\":\"$_tb\",\"TOUCH_THREAD_BOOST\":\"$_ttb\",\"UNLOCK_CDEV\":\"$_uc\",\"DISPLAY_PROTECT\":\"$_dp\",\"REPLACE_ENCRYPTED\":\"$_re\",\"SHOW_REAL_TEMP\":\"$_rt\",\"SPOOF_BATT\":\"$_sb\",\"SOC_T\":\"$_soc\",\"SKIN_T\":\"$_skin\",\"CAM_T\":\"$_cam\",\"BATT_T\":\"$_batt\",\"SHELL_PROC_T\":\"$_spt\",\"state\":\"$(_jesc "$_state")\",\"charging\":$_chg,\"emul_temp\":$_emu,\"zones_total\":$_zt,\"zones_spoofed\":$_zs,\"mounted\":$_mnt,\"android\":\"$(_jesc "$(getprop ro.build.version.release 2>/dev/null)")\",\"model\":\"$(_jesc "$(getprop ro.product.model 2>/dev/null)")\",\"version\":\"$(_jesc "$_ver")\",\"LOG_LEVEL\":\"$_lv\",\"BLACKLIST\":\"$(_jesc "$_bl")\",\"fuse_enable\":\"$_fuse_e\",\"fuse_trips\":$_fuse_n,\"fuse_last\":\"$(_jesc "$_fuse_last")\",\"safe_mode\":$_safe}"
}

# 实时温度：默认只返回关键温感
#   参数可含 --all  （返回全部温感）
#   参数可含 --real （附带真实温度：一次性暂停全部 emul_temp → 读取 → 恢复）
# 字段格式（临时文件）：优先级|类型|伪装读数|是否欺骗|目录|emul值|真实读数
get_temps() {
    _all=""; _real=""
    for _a in "$@"; do
        case "$_a" in
            --all)  _all="--all" ;;
            --real) _real="1" ;;
        esac
    done
    _limit="${TEMP_LIMIT:-10}"
    [ "$_all" = "--all" ] && _limit=9999

    # 真实温度探测总开关（mode.conf: SHOW_REAL_TEMP，默认 1）
    [ "$(conf_get "$MODE_CONF" SHOW_REAL_TEMP 1)" = "1" ] || _real=""

    # ── 自愈（必须在扫描前做）────────────────────────────────────
    # 上一轮探测若中途被杀，emul_temp 会停在 0（该温感欺骗失效）。若不先
    # 恢复，下面的扫描会把它们判成「未欺骗」，探测直接被跳过 —— 实机上
    # 表现为所有温感显示同一个值且没有「欺骗中」标记。
    if [ "$_real" = "1" ] && [ -s "$REAL_ZERO_MARK" ]; then
        while IFS='|' read -r _d _v; do
            [ -n "$_d" ] && [ -e "$_d/emul_temp" ] && \
                echo "$_v" > "$_d/emul_temp" 2>/dev/null
        done < "$REAL_ZERO_MARK"
        : > "$REAL_ZERO_MARK" 2>/dev/null
    fi

    # Android 上 /data/local/tmp 一定存在且可写，优先于不可靠的 TMPDIR
    _tmp="${TMPDIR:-/data/local/tmp}/gt8_temps.$$"
    : > "$_tmp" 2>/dev/null || _tmp="/data/local/tmp/gt8_temps.$$"
    : > "$_tmp" 2>/dev/null || return 1

    # 单次扫描，按重要度打优先级 —— 避免「类别 × 温感」的嵌套循环（真机上会
    # 产生几百次 fork）
    # 欺骗判定用记账清单（SPOOF_LIST）而非回读 emul_temp —— 见顶部说明。
    # v2.9.3：记账清单读入也零 fork 化（原来 `$(cat | tr | tr)` = 3 次 fork）。
    _sl=" "
    while IFS= read -r _sl_ln || [ -n "$_sl_ln" ]; do
        _sl_ln=${_sl_ln%"$CR_API"}
        [ -n "$_sl_ln" ] && _sl="$_sl$_sl_ln "
    done < "$SPOOF_LIST" 2>/dev/null
    # ── v2.11.0 温感树：标签所需的配置**每次请求只读一次** ─────────
    # 关键词：「一次」。下面这些值若放进 83 次的循环里逐个 conf_get，
    # 就是 83 次 sed fork —— 本模块的主体早已零 fork 化，不能在这里破功。
    _bl_pat=$(conf_get "$SPOOF_CONF" BLACKLIST '')
    _t_soc=$(conf_get "$SPOOF_CONF" SOC_T 29500)
    _t_skin=$(conf_get "$SPOOF_CONF" SKIN_T 29500)
    _t_cam=$(conf_get "$SPOOF_CONF" CAM_T 29500)
    _t_batt=$(conf_get "$SPOOF_CONF" BATT_T 29500)
    _sp_batt=$(conf_get "$SPOOF_CONF" SPOOF_BATT 1)

    _total=0
    for _z in "$TZ_BASE"/thermal_zone*; do
        [ -e "$_z/temp" ] || continue
        # v2.9.3：每温感 2 次 `$(cat)` + 1 次 `$(basename)` = 3 fork，83 温感
        # ≈249 fork。read 内建 + ${var##*/} 参数展开后归零，与 functions.sh 的
        # dump_temp 写法一致（那处 v2.8.13 已零 fork 化）。
        _ty=""; read -r _ty < "$_z/type" 2>/dev/null
        [ -n "$_ty" ] || _ty=${_z##*/}
        # v2.12.0（C-5）：内核原生 type 是标识符，但第三方模块可能 bind mount 伪造
        # 出含 | 或 " 的值 —— 那会让下面 `|` 分隔的中间格式错位、最终 JSON 非法。
        # 只在**确实命中**时才 fork 一次净化（常态零成本）。
        case "$_ty" in *'|'*|*'"'*) _ty=$(printf '%s' "$_ty" | tr -d '|"') ;; esac
        _t="";  read -r _t  < "$_z/temp" 2>/dev/null
        case "$_t" in ''|*[!0-9-]*) continue ;; esac
        _total=$((_total + 1))
        case "$_ty" in
            *batt*|*battery*)              _p=0 ;;
            *skin*|*shell*|*case*|*frame*) _p=1 ;;
            *cam*)                         _p=2 ;;
            *gpu*|*npu*)                   _p=3 ;;
            *cpu*|*cpuss*|*soc*|*cluster*) _p=4 ;;
            *usb*|*charge*|*conn*)         _p=5 ;;
            *quiet*|*xo*)                  _p=6 ;;
            *)  # PMIC / 射频内部传感等：默认不显示，--all 时排最后
                [ "$_all" = "--all" ] || continue
                _p=7 ;;
        esac
        _e=""; _s=0
        _needle="$_z|"
        case "$_sl" in
            *"$_needle"*)
                _e=${_sl#*"$_needle"}
                _e=${_e%% *}
                case "$_e" in ''|*[!0-9-]*) _e=0 ;; esac
                [ "$_e" != "0" ] && _s=1
                ;;
        esac

        # ── v2.11.0 温感树：一次 pass 同时算出「树分组 / 欺骗类别 / 目标值 / 排除原因」
        #   grp  层级可视化的分组。这是**展示概念**，可以比语义更宽 ——
        #        例如 vbat / ibat / bcl 都是电池相关，归到「电池 / 充电」组更好看。
        #        它不参与任何写入决策，所以宽一点没有副作用。
        #   cls  欺骗类别 —— 决定用哪个 *_T。这是**语义概念**，必须与
        #        functions.sh 的 zone_target_into 与 apply_spoof 的 SPOOF_BATT 跳过
        #        判定**逐字同规则**，否则界面会显示一个模块根本不会写的"目标温度"。
        #        因此它只用 batt/battery/usb 三条（不是上面那一串）。
        #        回归套件里有对拍断言：拿真机温感名逐一比对 cls→目标值 与
        #        zone_target_into 的输出（正是这条断言在开发期抓到了这里的偏差）。
        #   tgt  该类别的目标欺骗值（毫摄氏度）
        #   ex   该温感**本次为何没被欺骗**（空 = 正常参与）：
        #         noemul 内核不支持 emul_temp / bl 命中黑名单 / nobatt 电池类且 SPOOF_BATT=0
        case "$_ty" in
            *batt*|*battery*|*vbat*|*ibat*|*bcl*|*usb*|*charge*|*chg*|*conn*)
                _grp=batt ;;
            *shell*|*skin*|*case*|*frame*)
                _grp=shell ;;
            *cam*|*tof*|*flash*)
                _grp=cam ;;
            *gpu*|*npu*|*kgsl*)
                _grp=gpu ;;
            *cpu*|*cpuss*|*cluster*|*soc*)
                _grp=cpu ;;
            *ddr*|*ufs*|*mem*|*storage*)
                _grp=mem ;;
            *nsphvx*|*nsphmx*|*mdmss*|*modem*|*wifi*|*pa_therm*)
                _grp=rf ;;
            *video*|*audio*)
                _grp=av ;;
            *pm8550*|*pmih*|*pmr*|*pmx*|*pmic*)
                _grp=pmic ;;
            *disp*|*panel*|*backlight*)
                _grp=disp ;;
            *aoss*|*quiet*|*xo*|*sensor*|*sys-therm*|*therm*)
                _grp=sensor ;;
            *)
                _grp=other ;;
        esac
        case "$_ty" in
            *batt*|*battery*|*usb*)        _cls=batt ;;
            *shell*|*skin*|*case*|*frame*) _cls=skin ;;
            *cam*|*tof*|*flash*)           _cls=cam ;;
            *)                             _cls=soc ;;
        esac
        case "$_cls" in
            batt) _tgt=$_t_batt ;;
            skin) _tgt=$_t_skin ;;
            cam)  _tgt=$_t_cam  ;;
            *)    _tgt=$_t_soc  ;;
        esac
        _ex=""
        if [ ! -e "$_z/emul_temp" ]; then
            _ex=noemul
        elif [ -n "$_bl_pat" ]; then
            for _bl in $_bl_pat; do
                case "$_ty" in $_bl) _ex=bl; break ;; esac
            done
        fi
        if [ -z "$_ex" ] && [ "$_cls" = "batt" ] && [ "$_sp_batt" != "1" ]; then
            _ex=nobatt
        fi

        # 第 7 字段留给后面的真实温度探测；用 `-` 占位而不是留空 ——
        # 行尾若以 `|` 结束，不同 awk（gawk/mawk/toybox）对「尾随空字段」的
        # NF 处理不一致，会给下游解析埋雷。
        echo "${_p}|${_ty}|${_t}|${_s}|${_z}|${_e:-0}||${_grp}|${_cls}|${_tgt}|${_ex:--}" >> "$_tmp"
    done

    sort -t'|' -k1,1n "$_tmp" > "$_tmp.s" 2>/dev/null
    head -n "$_limit" "$_tmp.s" > "$_tmp.h"
    _n=$(wc -l < "$_tmp.h" | tr -d ' ')
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac

    # ---- 真实温度探测 ----------------------------------------------------
    # 原理：被欺骗温感的 temp 读数来自 emul_temp 仿真。要拿真实值，只能把
    #       emul_temp 短暂写 0（关闭仿真）→ 等内核刷新 → 读 temp → 写回伪装值。
    #
    # v2.8.1 修正（实机截图：所有「真实值」都等于伪装值 29.5）：
    #   1) 部分厂商内核在 emul_temp 写 0 后并不立刻刷新 temp，返回的仍是上次
    #      缓存的伪装值。现在「读到的值必须与伪装值不同」才算读到，否则逐轮
    #      加长等待重试（80ms → 320ms → 800ms）；仍读不到就如实返回空，
    #      前端显示「--」—— 绝不把伪装值冒充真实值。
    #   2) 每轮结束立刻恢复伪装值并清掉 REAL_ZERO_MARK；万一中途被杀，
    #      下次 get_temps 开头的自愈会按标记恢复（service.sh 周期重放兜底）。
    _pok=0; _ptot=0
    if [ "$_real" = "1" ] && [ -s "$_tmp.h" ]; then
        awk -F'|' '$4=="1"{print $5}' "$_tmp.h" > "$_tmp.d" 2>/dev/null
        if [ -s "$_tmp.d" ]; then
            # 待探测集合：目录|伪装值|扫描时的读数（=伪装值，用作失败判定基准）
            awk -F'|' '$4=="1"{print $5"|"$6"|"$3}' "$_tmp.h" > "$_tmp.p"
            _ms=$(conf_get "$MODE_CONF" REAL_TEMP_DELAY_MS 80)
            _rounds=0
            : > "$_tmp.r"
            while [ "$_rounds" -lt 3 ] && [ -s "$_tmp.p" ]; do
                _rounds=$((_rounds + 1))
                : > "$REAL_ZERO_MARK" 2>/dev/null
                # 关仿真（写 0）并回读确认；确认写成功的才进恢复标记
                # v2.9.3：read 内建替代 $(cat)（每温感每轮省 1 fork）
                while IFS='|' read -r _d _v _o; do
                    [ -e "$_d/emul_temp" ] || continue
                    echo 0 > "$_d/emul_temp" 2>/dev/null
                    _rb=""; read -r _rb < "$_d/emul_temp" 2>/dev/null
                    [ "$_rb" = "0" ] && echo "$_d|$_v" >> "$REAL_ZERO_MARK"
                done < "$_tmp.p"
                _msleep "$_ms"
                while IFS='|' read -r _d _v _o; do
                    _r=""; read -r _r < "$_d/temp" 2>/dev/null
                    case "$_r" in ''|*[!0-9-]*) _r="" ;; esac
                    if [ -n "$_r" ] && [ "$_r" != "$_o" ]; then
                        echo "$_d|$_r" >> "$_tmp.r"      # 可信：与伪装读数不同
                    else
                        echo "$_d|$_v|$_o" >> "$_tmp.f"  # 仍是伪装值 → 下轮重试
                    fi
                done < "$_tmp.p"
                # 立刻恢复伪装值，缩短暴露窗口
                while IFS='|' read -r _d _v; do
                    [ -n "$_d" ] && echo "$_v" > "$_d/emul_temp" 2>/dev/null
                done < "$REAL_ZERO_MARK"
                : > "$REAL_ZERO_MARK" 2>/dev/null
                mv -f "$_tmp.f" "$_tmp.p" 2>/dev/null || : > "$_tmp.p"
                if [ -s "$_tmp.p" ]; then
                    _ms=$((_ms * 4))
                    [ "$_ms" -gt 800 ] && _ms=800
                fi
            done
            _pok=$(wc -l < "$_tmp.r" 2>/dev/null | tr -d ' ')
            case "$_pok" in ''|*[!0-9]*) _pok=0 ;; esac
            _ptot=$(wc -l < "$_tmp.d" 2>/dev/null | tr -d ' ')
            case "$_ptot" in ''|*[!0-9]*) _ptot=0 ;; esac
            # 合并可信真实值到第 7 字段（BEGIN 里用 getline 预加载，避免依赖
            # awk 的 FILENAME/NR==FNR —— 在 toybox/busybox awk 上不可靠）
            # v2.9.3：原来用 `cat >` 回写（多一次 fork + 多一次全文件复制），
            # 改为 mv —— 语义相同（同样是覆盖 _tmp.h），少一次 I/O。
            awk -F'|' -v OFS='|' -v rf="$_tmp.r" '
                BEGIN {
                    while ((getline _l < rf) > 0) {
                        split(_l, _a, "|")
                        if (_a[1] != "") r[_a[1]] = _a[2]
                    }
                    close(rf)
                }
                { $7 = (($5 in r) ? r[$5] : ""); print }' "$_tmp.h" > "$_tmp.m" 2>/dev/null \
                && mv -f "$_tmp.m" "$_tmp.h" 2>/dev/null
        fi
    fi

    # v2.8.13 修复：探测结束做一次**全量重放** —— 以记账 SPOOF_LIST 为准，把所有
    # 欺骗值再写一遍。上面「写 0 → 读 → 写回」用临时变量 _v 恢复，万一某个温感
    # 写回失败、或被并发覆盖，就会停在 0（欺骗失效）；而 service.sh 的维护周期
    # 已从 30s 拉长到 120s，用户会观察到「读一次真实温度后欺骗就没了、要手动
    # 重放」。这里按记账全量重放，保证探测结束状态必然回到「记账应有的欺骗」，
    # 并顺手清掉残留的恢复标记。值都来自记账，与 service.sh 写的一致，幂等无害。
    if [ "$_real" = "1" ] && [ -s "$SPOOF_LIST" ]; then
        _rep=0
        while IFS='|' read -r _d _v; do
            [ -n "$_d" ] && [ -e "$_d/emul_temp" ] || continue
            echo "$_v" > "$_d/emul_temp" 2>/dev/null && _rep=$((_rep + 1))
        done < "$SPOOF_LIST"
        : > "$REAL_ZERO_MARK" 2>/dev/null
        # v2.10.3：补级别标签，并尊重 LOG_LEVEL。
        # 本脚本独立于 functions.sh（不 source 它，避免副作用），所以日志得自己拼；
        # 原先漏了 [INF]，导致分级后的日志里独独这一行没有标签（真机诊断包可见）。
        case "$(conf_get "$MODE_CONF" LOG_LEVEL info)" in
            warn|WARN|Warn|warning|2|error|ERROR|Error|err|3) ;;   # 阈值高于 info → 不写
            *) echo "[$(date '+%m-%d %H:%M:%S')] [INF] 真实温度探测完成：按记账重放 $_rep 个温感" \
                   >> "$LOG_FILE" 2>/dev/null ;;
        esac
    fi

    # v2.11.0：一并带出温感树所需的 grp(cls(tgt(ex 四个字段。
    #   $7 真实温度 / $8 分组 / $9 欺骗类别 / $10 该类目标值 / $11 未欺骗原因
    # ex == "-" 是"没有原因"的占位（见上面的扫描循环），这里翻译成不输出。
    _zones=$(awk -F'|' '{
        if (n++) printf ","
        rt = ($7 != "") ? ",\"real\":" $7 : ""
        ex = ($11 != "" && $11 != "-") ? ",\"ex\":\"" $11 "\"" : ""
        printf "{\"type\":\"%s\",\"temp\":%s,\"spoofed\":%s,\"grp\":\"%s\",\"cls\":\"%s\",\"tgt\":%s%s%s}",
               $2, $3, $4, $8, $9, $10, rt, ex
    }' "$_tmp.h")
    rm -f "$_tmp" "$_tmp.s" "$_tmp.h" "$_tmp.d" "$_tmp.v" "$_tmp.r" "$_tmp.m" "$_tmp.p" "$_tmp.f"
    echo "{\"success\":true,\"zones\":[$_zones],\"total\":$_total,\"shown\":$_n,\"all\":$([ "$_all" = "--all" ] && echo 1 || echo 0),\"real\":$([ "$_real" = "1" ] && echo 1 || echo 0),\"probe_ok\":$_pok,\"probe_total\":$_ptot}"
}

do_set() {
    shift 2>/dev/null
    _ds_n=0
    for _kv in "$@"; do
        # v2.9.3：原实现 `$(echo | cut -f1 -d '=')` + `cut -f2 -d '='` = 每对
        # 两次 fork，且 `-f2` 会把含 '=' 的值截断（如未来支持 URL 类值时）。
        # 参数展开零 fork 且语义正确：%%=* 取首个 '=' 之前、#*= 取其之后。
        case "$_kv" in
            *=*) _k=${_kv%%=*}; _v=${_kv#*=} ;;
            *)   continue ;;
        esac
        [ -n "$_k" ] || continue
        # v2.13.2（A2）：白名单统一到 schema_file，值域校验统一到 schema_valid
        # （C-3：非法值直接拒绝落盘，不再靠 load_conf 运行时兜底，避免界面与行为不一致）
        schema_file "$_k" || continue
        schema_valid "$_k" "$_v" || continue
        case "$_SC_FILE" in
            mode)  conf_set "$MODE_CONF" "$_k" "$_v" && _ds_n=$((_ds_n+1)) ;;
            spoof) conf_set "$SPOOF_CONF" "$_k" "$_v" && _ds_n=$((_ds_n+1)) ;;
        esac
    done
    command -v log >/dev/null 2>&1 && log -t "$LOG_TAG" "config updated: $*"
    # v2.11.2：没有任何键真正落盘时如实提示 —— 原实现空写入也报
    # 「已保存」，用户写了个不支持的键名会以为生效了。
    if [ "$_ds_n" = "0" ]; then
        echo '{"success":true,"message":"没有可保存的项（键名不在白名单或未提供键值）"}'
    else
        echo '{"success":true,"message":"已保存，5 秒内生效"}'
    fi
}

# v2.9.3：读日志尾部/全量。tr+sed+awk 三件套保留（JSON 转义必须逐字节处理，
# 且这是用户手动触发的诊断路径，不是热路径），但去掉多余的 `cat` 管道首段。
get_log() {
    _n="${LOG_TAIL_LINES:-50}"
    _rows=$(tail -n "$_n" "$LOG_FILE" 2>/dev/null \
        | tr -d '\000-\011\013-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk '{printf "%s\\n", $0}')
    echo "{\"success\":true,\"log\":\"$_rows\"}"
}

# v2.9.3：全量导出日志（与 get_log 相同的转义，只是不截断尾部），
# 供 WebUI「导出日志」按钮下载，便于离线排查运行状态。
get_log_full() {
    _rows=$(tr -d '\000-\011\013-\037' < "$LOG_FILE" 2>/dev/null \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk '{printf "%s\\n", $0}')
    echo "{\"success\":true,\"log\":\"$_rows\"}"
}

# v2.16.0 F5：温频历史快照（每行 epoch soc cpu0 cpu6 gpu，全整数无需转义）
get_history() {
    _rows=""
    _first=1
    while read -r _h_e _h_s _h_c0 _h_c6 _h_g; do
        [ -n "$_h_e" ] || continue
        case "$_h_e" in ''|*[!0-9]*) continue ;; esac
        [ "$_first" = "1" ] && _first=0 || _rows="$_rows,"
        _rows="$_rows[$_h_e,$_h_s,$_h_c0,$_h_c6,$_h_g]"
    done < "$HISTORY_LIST" 2>/dev/null
    echo "{\"success\":true,\"items\":[$_rows]}"
}

# v2.8.13：把日志复制到 /sdcard/Download（root 权限，浏览器下载目录不可控时的
# 确定性落盘位置）。文件名带时间戳，避免覆盖。失败时返回明确错误，前端据此降级。
get_save2download() {
    _dl="${DOWNLOAD_DIR:-/sdcard/Download}"
    _ts=$(date '+%Y%m%d_%H%M%S')
    _out="$_dl/gt8_thermal_$_ts.log"
    mkdir -p "$_dl" 2>/dev/null
    if [ -d "$_dl" ] && cp "$LOG_FILE" "$_out" 2>/dev/null && [ -f "$_out" ]; then
        _sz=$(wc -c < "$_out" 2>/dev/null | tr -d ' ')
        case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
        echo "{\"success\":true,\"path\":\"$_out\",\"size\":$_sz}"
    else
        echo "{\"success\":false,\"message\":\"写入 $_dl 失败（可能无 sdcard 权限）\"}"
    fi
}

# ── v2.10.0 诊断包 ─────────────────────────────────────────────
# 复用 action.sh 的 build_diagpack（那里已经 source 了 functions.sh，能拿到
# dump_temp / dump_cdev / load_conf 等全部工具）。本函数只负责：调用 →
# 从输出里解析出产物路径 → 包成 JSON 给 WebUI。
# 之所以不在这里重写一遍收集逻辑：单份实现才不会两边走偏。
get_diagpack() {
    _act="$MODDIR/action.sh"
    [ -f "$_act" ] || { echo '{"success":false,"message":"action.sh 不存在"}'; return; }
    _raw=$(DOWNLOAD_DIR="${DOWNLOAD_DIR:-/sdcard/Download}" sh "$_act" diagpack 2>&1)
    # 产物路径是输出里唯一以 .tar.gz / .txt 结尾的那一行
    _path=$(printf '%s\n' "$_raw" | grep -E '\.(tar\.gz|txt)$' | tail -n 1)
    if [ -z "$_path" ]; then
        # 降级：把原始输出回给前端，便于看失败原因（转义换行）
        _msg=$(_jesc "$(printf '%s' "$_raw" | tr '\n' ' ' | cut -c1-300)")
        echo "{\"success\":false,\"message\":\"$_msg\"}"
        return
    fi
    _sz=0
    [ -f "$_path" ] && _sz=$(wc -c < "$_path" 2>/dev/null | tr -d ' ')
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    echo "{\"success\":true,\"path\":\"$_path\",\"size\":$_sz}"
}

get_verify() {
    _emu=0
    for _z in "$TZ_BASE"/thermal_zone*; do
        [ -e "$_z/emul_temp" ] && { _emu=1; break; }
    done
    # 校验结论以模块记账 spoof.list 为准（v2.8.5）——部分厂商内核 emul_temp
    # 回读恒 0，用回读判定会误报「未欺骗」。horae 输出仅作参考。
    _zc=0
    [ -f "$SPOOF_LIST" ] && _zc=$(wc -l < "$SPOOF_LIST" 2>/dev/null | tr -d ' ')
    case "$_zc" in ''|*[!0-9]*) _zc=0 ;; esac
    echo "== 欺骗支持 == $( [ "$_emu" = "1" ] && echo "emul_temp 可用" || echo "不可用（回退激进模式）")"
    echo "== 当前状态 == $(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
    if [ "$_zc" -gt 0 ]; then
        echo "== 校验结论 == ✓ 通过（记账 $_zc 个温感已应用）"
    else
        echo "== 校验结论 == ✗ 未通过（记账为空）"
    fi
    echo "== horae 温度参考（不作为判据）=="
    if command -v dumpsys >/dev/null 2>&1; then
        _ho=$(dumpsys horae 2>/dev/null | grep -i 'temp' | head -n 3)
        [ -n "$_ho" ] && echo "$_ho" || echo "  (horae 无 temp 相关输出)"
    else
        echo "  (dumpsys 不可用)"
    fi
    echo "== 各温感读数 =="
    MODDIR_PARENT="$MODDIR"
    . "$MODDIR_PARENT/common/functions.sh" >/dev/null 2>&1
    load_conf
    dump_temp
}

# v2.13.0：一键体检 —— 复用 functions.sh 的 doctor_report。本脚本平时不 source
# functions.sh（避免副作用），doctor 是手动触发的诊断路径，这里只在函数内 source 一份。
get_doctor() {
    MODDIR_PARENT="$MODDIR"
    . "$MODDIR_PARENT/common/functions.sh" >/dev/null 2>&1
    _dr=$(doctor_report 2>/dev/null)
    echo "{\"success\":true,\"report\":\"$(_jesc "$_dr")\"}"
}

# ── 模块冲突检测（v2.8）─────────────────────────────────────────
#   与安装期 customize.sh 共用 common/conflicts.sh，判定规则一致。
get_conflicts() {
    MODULES_DIR="${MODULES_DIR:-/data/adb/modules}"
    SELF_ID="${SELF_ID:-realme-gt8-sukisu-thermal-remove}"
    . "$MODDIR/common/conflicts.sh" 2>/dev/null
    if ! command -v detect_conflicts >/dev/null 2>&1; then
        echo '{"success":false,"message":"冲突检测库不可用"}'
        exit 0
    fi
    _tmp="${TMPDIR:-/data/local/tmp}/gt8_conflicts.$$"
    : > "$_tmp" 2>/dev/null || _tmp="/data/local/tmp/gt8_conflicts.$$"
    detect_conflicts > "$_tmp" 2>/dev/null
    # 去控制字符 + 转义反斜杠与双引号，保证 JSON 一定合法
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$_tmp" 2>/dev/null \
        | tr -d '\000-\011\013-\037' > "$_tmp.e" 2>/dev/null
    _n=$(grep -c . "$_tmp.e" 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    _items=$(awk -F'|' '{
        if (n++) printf ","
        printf "{\"id\":\"%s\",\"name\":\"%s\",\"version\":\"%s\",\"risk\":\"%s\",\"note\":\"%s\"}",
               $1, $2, $3, $4, $5
    }' "$_tmp.e" 2>/dev/null)
    rm -f "$_tmp" "$_tmp.e"
    echo "{\"success\":true,\"count\":$_n,\"items\":[$_items]}"
}

# ═══════════════════════════════════════════════════════════════
#  v2.11.0 场景预设档
# ═══════════════════════════════════════════════════════════════
# 引擎在 common/presets.sh（api.sh 与 action.sh 共用同一份实现，不重复造）。
# 这里只负责三件事：懒加载引擎、把结果拼成 JSON、严格校验 preset id。
#
# 懒加载而不是文件顶部 source 的理由：--status / --temps 是 5 秒级高频路径，
# 不该为一个用户手动触发的功能常驻多付一次 source 的开销。
_load_preset_engine() {
    [ -n "${PRESET_ENGINE_READY:-}" ] && return 0
    [ -f "$MODDIR/common/presets.sh" ] || return 1
    . "$MODDIR/common/presets.sh" 2>/dev/null || return 1
    command -v preset_ids >/dev/null 2>&1 || return 1
    return 0
}

# 预设列表 + 当前配置与各档的匹配度。
# 「已应用 / 基于 X 改了 N 项 / 自定义」全部由匹配度**无状态**推得 ——
# 不记录"上次应用了哪档"，所以用户手改一个开关后界面会立刻如实变成"自定义"。
#
# 实现要点（fork 成本）：每个档的元数据先写成 **TAB 分隔的一行**，最后用**一次
# awk** 统一转义并拼成整段 JSON。若改成"每字段一次 sed 转义"就是 5 档 × 5 字段
# = 25 次 fork，只为处理我们自己写的中文短句 —— 在小内核/旧设备上这笔开销
# 比它转义的内容还贵。匹配度也走 _into 版（零子 shell），全程只剩 1 次 awk。
get_presets() {
    if ! _load_preset_engine; then
        echo '{"success":false,"message":"预设引擎不可用（common/presets.sh 缺失）"}'
        return
    fi
    _pst_tmp="${TMPDIR:-/data/local/tmp}/gt8_presets.$$"
    : > "$_pst_tmp" 2>/dev/null || _pst_tmp="/data/local/tmp/gt8_presets.$$"
    : > "$_pst_tmp" 2>/dev/null || { json_error "临时目录不可写"; return; }

    _best_id=""; _best_m=0; _best_t=0; _n=0
    for _pid in $(preset_ids); do
        preset_meta_into "$_pid" || continue
        preset_match_into "$_pid"
        _mm=$_PMT_M; _mtt=$_PMT_T
        _act=false
        [ "$_mtt" -gt 0 ] && [ "$_mm" = "$_mtt" ] && _act=true
        # 最接近的一档：交叉相乘比大小，不用浮点
        if [ "$_mm" -gt 0 ] && { [ -z "$_best_id" ] || \
             [ $((_mm * _best_t)) -gt $((_best_m * _mtt)) ]; }; then
            _best_id=$_pid; _best_m=$_mm; _best_t=$_mtt
        fi
        # keys 的键名与值都只含 [A-Za-z0-9_.-]，天然是合法 JSON 片段，无需转义
        _keys=""
        preset_pairs "$_pid" > "$_pst_tmp.k" 2>/dev/null
        while IFS= read -r _kv || [ -n "$_kv" ]; do
            case "$_kv" in *=*) ;; *) continue ;; esac
            _keys="$_keys${_keys:+,}\"${_kv%%=*}\":\"${_kv#*=}\""
        done < "$_pst_tmp.k"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$_pid" "$_PM_ICON" "$_PM_NAME" "$_PM_DESC" "$_PM_TAGS" "$_PM_RISK" \
            "$_PM_ORDER" "$_act" "$_mm" "$_mtt" "$_keys" >> "$_pst_tmp"
        _n=$((_n + 1))
    done
    rm -f "$_pst_tmp.k"

    if [ "$_n" = "0" ]; then
        rm -f "$_pst_tmp"
        echo '{"success":true,"count":0,"presets":[],"note":"presets/ 目录为空或不存在"}'
        return
    fi
    _arr=$(awk -F'\t' '
        # 逐字符转义：反斜杠与双引号加转义，控制字符（<空格）直接丢弃。
        # 逐字符而不是 gsub 正则，是为了不依赖各 awk 实现对 \001 之类
        # 八进制转义 / [[:cntrl:]] 字符类的支持差异（toybox awk 上不保险）。
        function jesc(s,   i, ch, out) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                ch = substr(s, i, 1)
                if (ch < " ") continue
                if (ch == "\\") { out = out "\\\\"; continue }
                if (ch == "\"") { out = out "\\\""; continue }
                out = out ch
            }
            return out
        }
        {
            # keys 是最后一个字段；万一元数据里混进了 TAB 导致多出字段，
            # 一律并回 keys（宁可 JSON 多一条奇怪键，也不要字段整体错位）
            keys = $11
            for (i = 12; i <= NF; i++) keys = keys "\t" $i
            if (n++) printf ","
            printf "{\"id\":\"%s\",\"icon\":\"%s\",\"name\":\"%s\",\"desc\":\"%s\",\"tags\":\"%s\",\"risk\":\"%s\",\"order\":%s,\"active\":%s,\"matched\":%s,\"total\":%s,\"keys\":{%s}}",
                   $1, jesc($2), jesc($3), jesc($4), jesc($5), jesc($6), $7, $8, $9, $10, keys
        }' "$_pst_tmp")
    rm -f "$_pst_tmp"
    echo "{\"success\":true,\"count\":$_n,\"best\":{\"id\":\"$_best_id\",\"matched\":$_best_m,\"total\":$_best_t},\"presets\":[$_arr]}"
}

# 应用某个预设。id 先过字符集白名单再看文件是否存在 —— 双重拦路径穿越。
set_preset() {
    _sp_id="$1"
    if ! _load_preset_engine; then
        json_error "预设引擎不可用"; return
    fi
    case "$_sp_id" in
        ''|*[!a-z0-9_-]*) json_error "非法的预设 id（只允许小写字母、数字、下划线、连字符）"; return ;;
    esac
    [ -f "$PRESET_DIR/$_sp_id.conf" ] || { json_error "预设不存在：$_sp_id"; return; }

    # 基线必须在 preset_apply **之前**装进缓存 —— 否则读回的是写后的值，
    # 每一项都和预设相等，"实际变了几项"会永远显示 0。
    _pm_cache_load

    _sa="$(_mktmp papply)" || { json_error "临时目录不可写"; return; }
    if ! preset_apply "$_sp_id" > "$_sa" 2>/dev/null; then
        rm -f "$_sa"
        json_error "应用失败：没有写入任何配置项"
        return
    fi
    # 与写前基线比对，得出「实际生效了几项」——
    # 用户关心的是"变了几项"，而不是"写了几项"（整档 23 项里通常只变几项）。
    _changed=""; _cn=0; _wn=0
    while IFS= read -r _kv || [ -n "$_kv" ]; do
        case "$_kv" in *=*) ;; *) continue ;; esac
        _kk=${_kv%%=*}; _vv=${_kv#*=}
        _wn=$((_wn + 1))
        _pm_cache_get "$_kk"
        [ "$_PM_CUR" = "$_vv" ] && continue
        _cn=$((_cn + 1))
        _changed="$_changed${_changed:+,}\"$_kk\""
    done < "$_sa"
    rm -f "$_sa"
    preset_meta_into "$_sp_id"
    echo "{\"success\":true,\"id\":\"$_sp_id\",\"name\":\"$(_jesc "$_PM_NAME")\",\"written\":$_wn,\"changed\":$_cn,\"keys\":[$_changed],\"message\":\"已应用「$(_jesc "$_PM_NAME")」：$_wn 项写入、其中 $_cn 项发生变化，5 秒内生效\"}"
}

# ── v2.11.0：BLACKLIST 专用写入口 ───────────────────────────────
# 为什么不复用 --set：前端的 sanitize() 在 KSU 通道下会剥掉空格与 `*`，
# 而 BLACKLIST 的值恰恰是「空格分隔的通配符列表」；CGI 通道同理 —— do_set
# 用 `tr '&' ' '` 拆参且不做 URL 解码，空格会以 %20 原样落盘。
# 所以给它一条专用通道：值作为**单个参数**传递，此处再解码 %20。
set_blacklist() {
    # 严格净化：配置是行式纯文本，值里出现换行等于注入任意键。
    # 只放行 通配符/字母数字/.:_-? ，其余（换行、引号、分号、$ 等）一律变空格。
    _sb_v=$(printf '%s' "$1" \
        | sed -e 's/%20/ /g' -e 's/[^A-Za-z0-9*?_.:+-]/ /g' \
        | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')
    [ "${#_sb_v}" -gt 1024 ] && _sb_v=$(printf '%s' "$_sb_v" | cut -c1-1024)
    conf_set "$SPOOF_CONF" BLACKLIST "$_sb_v" || { json_error "写入 spoof.conf 失败"; return; }
    _n=0
    for _x in $_sb_v; do _n=$((_n + 1)); done
    echo "{\"success\":true,\"count\":$_n,\"value\":\"$(_jesc "$_sb_v")\",\"message\":\"黑名单已更新（$_n 条规则），5 秒内生效\"}"
}

case "$1" in
    --status) get_status; exit 0 ;;
    --temps)  get_temps "$2" "$3"; exit 0 ;;
    --set)    do_set "$@"; exit 0 ;;
    --log)    get_log;    exit 0 ;;
    --history) get_history; exit 0 ;;
    --exportlog) get_log_full; exit 0 ;;
    --save2download) get_save2download; exit 0 ;;
    --diagpack) get_diagpack; exit 0 ;;
    --verify) get_verify; exit 0 ;;
    --conflicts) get_conflicts; exit 0 ;;
    --doctor) get_doctor; exit 0 ;;
    --presets) get_presets; exit 0 ;;
    --preset)  set_preset "$2"; exit 0 ;;
    --setlist) set_blacklist "$2"; exit 0 ;;
esac

json_header
[ "$REQUEST_METHOD" = "OPTIONS" ] && exit 0

case "$QUERY_STRING" in
    *action=status*) get_status ;;
    *action=temps*)
        _a=""; _r=""
        case "$QUERY_STRING" in *all=1*)  _a="--all"  ;; esac
        case "$QUERY_STRING" in *real=1*)
            # v2.11.2：real=1 会短暂写 emul_temp（写路径）→ 同样拦跨源
            _cgi_origin_ok || { json_error "拒绝跨源写请求"; exit 0; }
            _r="--real" ;;
        esac
        get_temps $_a $_r ;;
    *action=log*)    get_log    ;;
    *action=exportlog*) get_log_full ;;
    *action=save2download*) get_save2download ;;
    *action=diagpack*) get_diagpack ;;
    *action=conflicts*) get_conflicts ;;
    *action=doctor*) get_doctor ;;
    # v2.11.0：注意 presets 必须排在 preset 之前 —— case 是首个匹配生效，
    # 否则 action=presets 会被 action=preset 抢走、id 解析出 "s"。
    *action=presets*) get_presets ;;
    *action=preset*)
        _cgi_origin_ok || { json_error "拒绝跨源写请求"; exit 0; }
        _pid=""
        case "$QUERY_STRING" in *id=*) _pid=${QUERY_STRING#*id=}; _pid=${_pid%%&*} ;; esac
        set_preset "$_pid" ;;
    *action=setlist*)
        _cgi_origin_ok || { json_error "拒绝跨源写请求"; exit 0; }
        _sv=""
        case "$QUERY_STRING" in *v=*) _sv=${QUERY_STRING#*v=}; _sv=${_sv%%&*} ;; esac
        set_blacklist "$_sv" ;;
    *action=set*)
        _cgi_origin_ok || { json_error "拒绝跨源写请求"; exit 0; }
        [ "$REQUEST_METHOD" = "POST" ] || { json_error "必须使用POST方法"; exit 0; }
        if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
            _post=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
        else
            read -r _post
        fi
        _args=$(echo "$_post" | tr '&' ' ')
        do_set x $_args
        ;;
    *) json_error "未知操作，支持 action=status|temps|set|setlist|log|exportlog|save2download|diagpack|verify|conflicts|presets|preset" ;;
esac
exit 0
