#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════
#  安装时执行：机型校验 + 扫描并改写 OPPO/realme 私有温控配置
#
#  思路来自 HORAE Extreme：不粗暴清空配置（容易让 Thermal HAL 崩溃），
#  而是保留文件结构、只把里面的阈值/开关改掉。
#
#  改写结果不再直接铺到模块根分区，而是分两级写入：
#    patched/thermal  —— 核心温控集（PATCH_THERMAL 控制，默认开）
#    patched/extra    —— 扩展集（PATCH_EXTRA 控制，默认关）
#  运行时由 common/functions.sh 的 mount_config_overlays 按需 bind 挂载，
#  随时可在 WebUI 里单独开关、出问题立刻卸载。
# ═══════════════════════════════════════════════════════════════

if ! type ui_print >/dev/null 2>&1; then ui_print() { echo "$@"; }; fi

MODPATH="${MODPATH:-${0%/*}}"
module="$MODPATH"
PATCH_DIR="$module/patched"

# ── 读取开关（与运行时共用同一份 mode.conf）────────────────────
# v2.8.4：与 common/functions.sh / api.sh 的 conf_get 保持同一实现
# （纯 shell 去壳，省掉两次 sed + 一个管道）。安装期不 source functions.sh
# —— 那会执行建目录、读 getprop、source conflicts.sh 等运行时副作用。
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
    _v=$(sed -n "s/^$_k=//p" "$_f" 2>/dev/null | head -n 1)
    if [ -n "$_v" ]; then
        _strip "$_v"
        _v="$_sv"
    fi
    [ -z "$_v" ] && _v="$_d"
    echo "$_v"
}
PATCH_THERMAL=$(conf_get "$module/mode.conf" PATCH_THERMAL 1)
PATCH_EXTRA=$(conf_get "$module/mode.conf" PATCH_EXTRA 0)
REPLACE_ENCRYPTED=$(conf_get "$module/mode.conf" REPLACE_ENCRYPTED 0)
SPOOF_BATT=$(conf_get "$module/spoof.conf" SPOOF_BATT 1)

# 需要扫描的分区（含 OPPO/realme 私有分区）
dirs="/odm /my_product /my_stock /my_heytap /my_bigball /my_odm /vendor /system/vendor /product /system"

# ── 机型与版本信息 ────────────────────────────────────────────
BRAND=$(getprop ro.product.brand 2>/dev/null)
MODEL=$(getprop ro.product.model 2>/dev/null)
DEVICE=$(getprop ro.product.device 2>/dev/null)
BOARD=$(getprop ro.board.platform 2>/dev/null)
SKU=$(getprop ro.boot.product.hardware.sku 2>/dev/null)
REL=$(getprop ro.build.version.release 2>/dev/null)
SDK=$(getprop ro.build.version.sdk 2>/dev/null)
UI=$(getprop ro.build.version.realmeui 2>/dev/null)
DISP=$(getprop ro.build.display.id 2>/dev/null)
SOC_MODEL=$(getprop ro.soc.model 2>/dev/null | tr 'a-z' 'A-Z')
MFR=$(getprop ro.product.odm.manufacturer 2>/dev/null)

ui_print "──────────────────────────────"
ui_print " 设备 : $BRAND $MODEL"
ui_print " 代号 : $DEVICE / $SKU"
ui_print " 平台 : $BOARD ${SOC_MODEL:+($SOC_MODEL)}"
ui_print " 厂商 : ${MFR:-未知}"
ui_print " 系统 : Android ${REL:-?} (SDK ${SDK:-?})"
ui_print " 版本 : ${UI:-未知} ${DISP:+($DISP)}"
ui_print "──────────────────────────────"

case "$MODEL$DEVICE$SKU" in
    *GT8*|*gt8*|RMX5*|RMX66*|RMX67*) ui_print " ✔ 检测到真我 GT8 系列（$MODEL）" ;;
    *) ui_print " ! 未识别到真我 GT8（$MODEL），效果未验证" ;;
esac

if [ -n "$SDK" ] && [ "$SDK" -ge 36 ] 2>/dev/null; then
    ui_print " ✔ Android 16+：启用 AIDL HAL / cooling_device 归零"
else
    ui_print " ! 当前 Android ${REL:-?}，本版针对 Android 16 调校"
fi

case "$DISP$UI" in
    *16.0.0.263*) ui_print " ✔ 匹配已验证版本 16.0.0.263" ;;
    *7.0*)        ui_print " - realme UI 7.0，版本号与已验证版略有差异" ;;
esac

ui_print ""

# ── 冲突自检（v2.8）────────────────────────────────────────────
#  温控类模块不是各管一摊，而是往同一批资源上写：thermal_zone*/emul_temp、
#  horae 服务、/proc/shell-temp、sys_thermal*/game_thermal XML、cooling_device。
#  同时装两个 →「最后执行者获胜」，温控行为随机、亮度异常等难以复现。
#  这里只告警，不阻断安装 —— 卸载哪一个由用户决定。
if [ "$(conf_get "$module/mode.conf" CHECK_CONFLICTS 1)" = "1" ]; then
    MODULES_DIR="${MODULES_DIR:-/data/adb/modules}" \
    SELF_ID="$(conf_get "$module/module.prop" id realme-gt8-sukisu-thermal-remove)"
    # 安装期一次性开销可接受，这里强制开启 Tier C（按资源占用扫描）；
    # 运行时主循环保持关闭，见 mode.conf 的 SCAN_RESOURCES 说明。
    SCAN_RESOURCES=1
    export SCAN_RESOURCES
    . "$module/common/conflicts.sh" 2>/dev/null && {
        if [ ! -d "$MODULES_DIR" ]; then
            ui_print " - 模块目录不可用，跳过冲突自检"
        else
            _cf=$(detect_conflicts)
            if [ -n "$_cf" ]; then
                ui_print " ⚠ 检测到其他温控模块（会争抢同一批资源）："
                print_conflicts "   " | while IFS= read -r _l; do ui_print "$_l"; done
                ui_print "   装多个不会叠加效果，只会互相覆盖 —— 建议只保留一个"
            else
                ui_print " ✔ 未检测到其他温控模块"
            fi
        fi
    }
    ui_print ""
fi

ui_print "- 改写开关：thermal=$PATCH_THERMAL  extra=$PATCH_EXTRA  加密替换=$REPLACE_ENCRYPTED"
ui_print "- 开始扫描并改写温控配置..."

mkdir -p "$PATCH_DIR/thermal" "$PATCH_DIR/extra" 2>/dev/null

# ── 关掉 OPPO 的高温相关属性 ─────────────────────────────────
# 注意：v2.3 移除 persist.sys.environment.temp —— 该属性语义不明（疑似环境
# 温度，单位也不确定），写入未知值可能参与亮度/充电策略，不再动它
setprop persist.sys.oplus.wifi.sla.game_high_temperature 50 2>/dev/null

# ── 通用 XML 键值改写 ─────────────────────────────────────────
# $1 = 目标集(thermal|extra)，$2 = 文件名（支持通配符），$3 = 多行 key=value 文本
#
# 实现说明（v2.8.4 修复）：调用方传入的是一个「多行」键值表（见下方两处调用），
# 因此 $3 是一个含换行的字符串。旧实现用 `for _ov in "$@"` 只会迭代这一个整块
# 字符串，再 `cut -f1` 按行切分后 _key 变成 "isOpen\nmore_heat_threshold\n…"，
# 拼进 sed 导致表达式非法（unterminated `s' command），_rows 被清空 →
# patched 文件变成空文件，而 _found 仍自增、日志照样打印「× N」具有欺骗性；
# 运行时该空文件会被 bind mount 覆盖真机 XML。
#
# 现在：把多行键值表按行拆开，每行编译成一条 sed -e 表达式，最后用单次 sed
# 原地完成全部替换 —— 无管道、无子 shell、只读一次文件、只写一次输出。
xml_override() {
    _set="$1"; _name="$2"; _pairs="$3"
    _found=0
    for _file in $(find $dirs -name "$_name" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/$_set$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        # 逐行编译 sed 表达式（set -- 累积位置参数，POSIX 安全）
        # v2.8.4：模式由 <K>.*</ 改为 <K>[^<]*</ —— 原模式里的 .* 会跨标签
        # 贪婪匹配：同一行有多个标签时（如 <isOpen>true</isOpen><Switch>true</Switch>）
        # 改 isOpen 会把后面整个标签吞掉，产出 <isOpen>0</Switch> 这种
        # 标签不闭合的损坏 XML。标签独占一行时（真机实际格式）两者等价。
        set --
        _oi="$IFS"; IFS='
'
        for _ov in $_pairs; do
            [ -n "$_ov" ] || continue
            _key=${_ov%%=*}
            _val=${_ov#*=}
            set -- "$@" "-e" "s/<$_key>[^<]*</<$_key>$_val</"
        done
        IFS="$_oi"
        if [ "$#" -gt 0 ]; then
            sed "$@" "$_file" > "$_out" 2>/dev/null && _found=$((_found + 1))
        else
            # 键值表为空：原样拷贝，保证 bind mount 的文件内容与源一致
            cp "$_file" "$_out" 2>/dev/null && _found=$((_found + 1))
        fi
    done
    [ "$_found" -gt 0 ] && ui_print "   · $_name × $_found"
}

# ══════════════ 核心温控集（PATCH_THERMAL）════════════════════
if [ "$PATCH_THERMAL" = "1" ]; then

    # ── sys_thermal_control_config*.xml：关开关 + 等级置 -1 ──────
    boolValues="feature_enable_item feature_safety_test_enable_item aging_thermal_control_enable_item"
    intValues="aging_cpu_level_item high_temp_safety_level_item game_high_perf_mode_item normal_mode_item ota_mode_item racing_mode_item"
    _n=0
    _today_version=$(date +"%Y%m%d01")
    for _file in $(find $dirs -name "sys_thermal_control_config*.xml" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/thermal$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        # 部分 ROM 的该文件是加密/二进制的，不是合法 XML
        if head -c 32 "$_file" 2>/dev/null | grep -q '<?xml\|<sys_thermal'; then
            _rows=$(cat "$_file" | grep -v -E '(<gear_config|cpu=|fps=|<scene_|</scene_|<category_|</category_|<subitem|<level|\.)')
            for _key in $boolValues; do
                _rows=$(echo "$_rows" | sed "s/<$_key.*\/>/<$_key booleanVal=\"false\" \/>/")
            done
            for _key in $intValues; do
                _rows=$(echo "$_rows" | sed "s/<$_key.*\/>/<$_key intVal=\"-1\" \/>/")
            done
            echo "$_rows" | tr -s '\n' > "$_out" 2>/dev/null && _n=$((_n + 1))
        elif [ "$REPLACE_ENCRYPTED" = "1" ] && [ -f "$module/sys_thermal_control_config_default.xml" ]; then
            sed "s/<version>.*<\/version>/<version>${_today_version}<\/version>/" \
                "$module/sys_thermal_control_config_default.xml" > "$_out" 2>/dev/null && _n=$((_n + 1))
            ui_print "   · $_file 非明文 XML，已用预置空策略替换"
        else
            ui_print "   · $_file 非明文 XML，已跳过（REPLACE_ENCRYPTED=0）"
        fi
    done
    [ "$_n" -gt 0 ] && ui_print "   · sys_thermal_control_config*.xml × $_n"

    # ── sys_thermal_config.xml ──────────────────────────────────
    xml_override thermal 'sys_thermal_config.xml' "isOpen=0
more_heat_threshold=550
heat_threshold=530
less_heat_threshold=500
preheat_threshold=480
preheat_dex_oat_threshold=460
thermal_battery_temp=0
is_feature_on=0
is_upload_log=0
is_upload_errlog=0"

    # ── sys_high_temp_protect*.xml ──────────────────────────────
    xml_override thermal 'sys_high_temp_protect*xml' "isOpen=0
HighTemperatureProtectSwitch=false
HighTemperatureShutdownSwitch=false
HighTemperatureFirstStepSwitch=false
HighTemperatureProtectFirstStepIn=550
HighTemperatureProtectFirstStepOut=530
HighTemperatureProtectThresholdIn=570
HighTemperatureProtectThresholdOut=550
HighTemperatureProtectShutDown=750
MediumTemperatureProtectThreshold=10000
HighTemperatureDisableFlashSwitch=false
HighTemperatureDisableFlashLimit=480
HighTemperatureEnableFlashLimit=470
HighTemperatureDisableFlashChargeSwitch=false
HighTemperatureDisableFlashChargeLimit=480
HighTemperatureEnableFlashChargeLimit=470
camera_temperature_limit=520
HighTemperatureControlVideoRecordSwitch=false
HighTemperatureDisableVideoRecordLimit=550
HighTemperatureEnableVideoRecordLimit=520
ToleranceThreshold=50
ToleranceStart=480
ToleranceStop=460"

    # ── game_thermal_config.xml：cluster 限制全部置 -1 ────────────
    _n=0
    for _file in $(find $dirs -name "game_thermal_config.xml" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/thermal$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        if grep -q cluster3 "$_file" 2>/dev/null; then
            _c3='cluster3="-1" '
        else
            _c3=''
        fi
        {
            echo '<?xml version="1.0" encoding="utf-8"?>'
            echo '<game_thermal_config>'
            echo '    <version>20230829</version>'
            echo '    <filter-name>game_thermal_config</filter-name>'
            echo '    <heavy_policy>'
            echo "        <game_control temp=\"520\" cluster0=\"-1\" cluster1=\"-1\" cluster2=\"-1\" $_c3 fps=\"60\"/>"
            echo '    </heavy_policy>'
            echo '    <default_policy>'
            for _t in 430 440 450 460 470 480 490 510; do
                echo "        <game_control temp=\"$_t\" cluster0=\"-1\" cluster1=\"-1\" cluster2=\"-1\" $_c3 fps=\"0\"/>"
            done
            echo '    </default_policy>'
            echo '</game_thermal_config>'
        } > "$_out" 2>/dev/null && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && ui_print "   · game_thermal_config.xml × $_n"

    # ── QEGA_Config.txt ─────────────────────────────────────────
    _n=0
    for _file in $(find $dirs -name "QEGA_Config.txt" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/thermal$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        echo "SkinTemperatureNode:   battery
SkinNodeThrottleTemp:  55000
#GameID   GameAPK    MaxTemperature  MaxCurrent  AvgCurrent
100001    hok         52000          2000        1800
0         adaptive    55000          2000        1800" > "$_out" 2>/dev/null && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && ui_print "   · QEGA_Config.txt × $_n"

else
    ui_print "   · 核心温控改写集已跳过 (PATCH_THERMAL=0)，仅靠 emul_temp 欺骗生效"
fi

# ══════════════ 扩展集（PATCH_EXTRA，默认关闭）═════════════════
if [ "$PATCH_EXTRA" = "1" ]; then

    # ── thermallevel_to_fps.xml：温度等级→帧率映射，全部拉满 ──────
    _n=0
    for _file in $(find $dirs -name "thermallevel_to_fps.xml" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/extra$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        sed 's/fps="[^"]*"/fps="144"/g' "$_file" > "$_out" 2>/dev/null && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && ui_print "   · thermallevel_to_fps.xml × $_n"

    # ── oppo_display_perf_list.xml：只保留系统与显示相关条目 ──────
    #    ⚠ 直接关系显示行为，若出现亮度/刷新率异常请在 WebUI 关掉 PATCH_EXTRA
    _n=0
    for _file in $(find $dirs -name "oppo_display_perf_list.xml" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/extra$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        : > "$_out" 2>/dev/null
        _skip=0
        while IFS= read -r _line; do
            case "$_line" in
                *"<name>"*)
                    case "$_line" in
                        *"sf.dps.feature"*|*"com.android"*|*"system_server"*|*"/system"*|*"com.color"*|*"com.oppo"*|*"com.oplus"*)
                            _skip=0; echo "  $_line" >> "$_out" ;;
                        *) _skip=1 ;;
                    esac
                    ;;
                '<?xml version="1.0" encoding="UTF-8"?>'|'<filter-conf>'|'</filter-conf>')
                    echo "$_line" >> "$_out" ;;
                *)
                    [ "$_skip" = "0" ] && echo "  $_line" >> "$_out" ;;
            esac
        done < "$_file"
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && ui_print "   · oppo_display_perf_list.xml × $_n"

    # ── qapegameconfig.txt：游戏温度/电流上限 ────────────────────
    _n=0
    for _file in $(find $dirs -name "qapegameconfig.txt" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/extra$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        echo "#GameID   GameAPK          MaxTemperature  MaxCurrent  AvgCurrent
100001    hok                 55000          2000        1800
0         adaptive            55000          2000        1800" > "$_out" 2>/dev/null && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && ui_print "   · qapegameconfig.txt × $_n"

    # ── devices_config.json：放宽电池温度区间 ────────────────────
    _n=0
    for _file in $(find $dirs -name "devices_config.json" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/extra$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        : > "$_out" 2>/dev/null
        while IFS= read -r _line; do
            case "$_line" in
                *'"high.capacity.threshold": 100'*) echo "$_line" >> "$_out" ;;
                *'"battery.temperate.range":'*)     echo '"battery.temperate.range": "[100,500]",' >> "$_out" ;;
                *'"high.capacity.battery.temperate.range":'*) echo '"high.capacity.battery.temperate.range": "[100,500]",' >> "$_out" ;;
                *'"high.capacity.threshold":'*)     echo '"high.capacity.threshold": 85' >> "$_out" ;;
                *) echo "$_line" >> "$_out" ;;
            esac
        done < "$_file"
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && ui_print "   · devices_config.json × $_n"

    # ── charging_*txt：温度门槛 +5°C ────────────────────────────
    _n=0
    for _file in $(find $dirs -name "charging_*txt" 2>/dev/null); do
        [ -f "$_file" ] || continue
        _out="$PATCH_DIR/extra$_file"
        mkdir -p "$(dirname "$_out")" 2>/dev/null
        : > "$_out" 2>/dev/null
        while IFS= read -r _line; do
            case "$_line" in
                *:=*) echo "$_line" >> "$_out" ;;
                *,*,*)
                    _t=$(echo "$_line" | awk -F, '{print $1}')
                    _c=$(echo "$_line" | awk -F, '{print $2}')
                    _x=$(echo "$_line" | awk -F, '{print $3}')
                    _t=$((_t + 50))
                    echo "$_t,$_c,$_x" >> "$_out"
                    ;;
                *) echo "$_line" >> "$_out" ;;
            esac
        done < "$_file"
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && ui_print "   · charging_*txt × $_n"

else
    ui_print "   · 扩展改写集已跳过 (PATCH_EXTRA=0)"
    ui_print "     含 oppo_display_perf_list.xml / thermallevel_to_fps.xml /"
    ui_print "     devices_config.json / charging_* —— 这些直接关联显示与充电行为"
fi

# ── 生成清单，方便排查 ────────────────────────────────────────
for _s in thermal extra; do
    find "$PATCH_DIR/$_s" -type f 2>/dev/null | sed "s|^$PATCH_DIR/$_s||" \
        > "$PATCH_DIR/$_s.list" 2>/dev/null
done

# ══════════ 已知配置清单核对（v2.8.7）════════════════════════
#  来源：本机历史积累 + 横评第三方模块（Aurorawk「ColorOS去温控」9 类清单、
#        慕容 ColorOS 附加模块）后补齐。
#
#  核对结果（本模块此前缺失 2 项，现已登记）：
#    refresh_rate_config.xml        ← 第三方必扫，我们此前完全没纳入
#    sys_resolution_switch_config.xml ← 同上
#
#  ⚠ 这两项**刻意不改写**：
#    · refresh_rate_config.xml 的 rateId 语义在不同模块里互相矛盾 ——
#      Aurorawk 把 "2-2-2-2" 改成 "0-0-0-0"，慕容把全部项改成 "3-3-3-3"（锁 120Hz）。
#      同一个字段、两种相反改法，说明它既可能是「温区→刷新率降级映射」，
#      也可能是「档位索引」。盲改等于掷骰子：GT8 若是 144Hz 面板，
#      照抄慕容反而是降级。
#    · sys_resolution_switch_config.xml 是真机未验证结构的分辨率切换表，
#      对方的做法是删掉所有 <switchop package> 行（= 禁止切分辨率）。
#      我们刚在 v2.8.4 修过「改写产出损坏 XML」的 P0，不为这类文件破例。
#    · 更根本的：本模块靠 emul_temp 让系统以为不热，温度假了降帧/降分辨率
#      本就不会触发 —— 改这两个文件是冗余手段，风险却高得多。
#
#  所以这里只做「登记 + 可见化」：把它们扫出来写进 known.list，
#  让「有没有这个文件 / 有没有被别的模块覆盖」成为可查信息，而不是静默。
KNOWN_CFG="sys_thermal_control_config.xml
sys_thermal_config.xml
sys_high_temp_protect.xml
game_thermal_config.xml
QEGA_Config.txt
thermallevel_to_fps.xml
oppo_display_perf_list.xml
qapegameconfig.txt
devices_config.json
charging_config.txt
refresh_rate_config.xml
sys_resolution_switch_config.xml"

: > "$PATCH_DIR/known.list" 2>/dev/null
_seen_n=0
_patched_n=0
if [ "$(conf_get "$module/mode.conf" CHECK_KNOWN_CFG 1)" = "1" ]; then
# 注意：这里绝不能像 xml_override 那样把 IFS 改成「仅换行」—— $dirs 是空格
# 分隔的多个分区，分词一变窄它就会被当成一个不存在的单路径，find 静默空转。
# 文件名都不含空格，用默认 IFS（空格 + 换行都分词）反而天然正确。
for _kn in $KNOWN_CFG; do
    [ -n "$_kn" ] || continue
    for _file in $(find $dirs /data/system -name "$_kn" 2>/dev/null); do
        [ -f "$_file" ] || continue
        if [ -f "$PATCH_DIR/thermal$_file" ] || [ -f "$PATCH_DIR/extra$_file" ]; then
            echo "patched|$_file" >> "$PATCH_DIR/known.list"
            _patched_n=$((_patched_n + 1))
        else
            echo "seen|$_file" >> "$PATCH_DIR/known.list"
            _seen_n=$((_seen_n + 1))
        fi
    done
done
ui_print "   · 已知配置核对：已改写 $_patched_n 个，发现未改写 $_seen_n 个"
fi

# ══════════ /data/system 运行时副本快照（v2.8.7）══════════════
#  refresh_rate_config.xml 这类配置，系统会在 /data/system/ 维护一份「运行时
#  副本」，它优先于分区里的原始文件（Aurorawk 就是为这个额外改了一份）。
#  副本一旦被某个模块 sed -i 改坏，且对方没有 uninstall.sh，就再也无法还原
#  —— 这正是「刷新率/亮度异常怎么都查不出来」的典型成因。
#
#  本模块不改它（理由见上），但做一件低成本高价值的事：**首次安装时快照一份**。
#  快照放在 /data/adb/thermal_remove/runtime_backup/ —— 刻意放在模块目录之外，
#  这样即使卸载本模块，快照仍在，随时可还原。
#  只在快照不存在时才写入，二次安装不会把「已改坏的版本」覆盖成新的基准。
if [ "$(conf_get "$module/mode.conf" RUNTIME_SNAPSHOT 1)" = "1" ] && [ -d /data/system ]; then
    _rb="${PERSIST_DIR:-/data/adb/thermal_remove}/runtime_backup"
    mkdir -p "$_rb" 2>/dev/null
    _snap_n=0
    for _kn in refresh_rate_config.xml sys_resolution_switch_config.xml \
               oplus_vrr_config.json; do
        [ -f "/data/system/$_kn" ] || continue
        if [ -f "$_rb/$_kn" ]; then
            echo "kept|/data/system/$_kn" >> "$PATCH_DIR/known.list"
        else
            cp "/data/system/$_kn" "$_rb/$_kn" 2>/dev/null && {
                echo "snapshot|/data/system/$_kn" >> "$PATCH_DIR/known.list"
                _snap_n=$((_snap_n + 1))
            }
        fi
    done
    [ "$_snap_n" -gt 0 ] && ui_print "   · 已快照 $_snap_n 个 /data/system 运行时副本 → $_rb"
fi

# ── v2.8.11：VRR 亮度字段基线 ──────────────────────────────────
# 为什么要基线：oplus_vrr_config.json 里的 hw_nit_limit 是**厂商自己设的值**
# （GT8 实测原厂 = 50，第三方「ColorOS 显示优化」那份把它改成 0）。
# v2.8.10 把它当「非 0 = 被钳制」来报 → 在没刷任何模块时也天天报 ⚠，是新的假阳性。
# 而这个字段的语义并不真是「nit 上限」（dumpsys 里同样是 50/90 的是亮度曲线百分比，
# 不是 nits），光看绝对值根本判断不了好坏 —— 唯一可靠的办法是**和原厂基线比**。
# 刻意不写死 50：固件更新会变，基线必须来自设备自身。
if [ "$(conf_get "$module/mode.conf" RUNTIME_SNAPSHOT 1)" = "1" ] && \
   [ -s /my_product/etc/oplus_vrr_config.json ]; then
    _vb="${PERSIST_DIR:-/data/adb/thermal_remove}/vrr_baseline.list"
    if [ -f "$_vb" ]; then
        echo "kept|$_vb" >> "$PATCH_DIR/known.list"
    else
        : > "$_vb.tmp" 2>/dev/null
        for _vk in hw_nit_limit hw_nit_limit_pwm; do
            _vv=$(sed -n "s/.*\"$_vk\"[[:space:]]*:[[:space:]]*[\"]*\([0-9.-]*\).*/\1/p" \
                   /my_product/etc/oplus_vrr_config.json 2>/dev/null | head -n 1)
            [ -n "$_vv" ] && echo "$_vk=$_vv" >> "$_vb.tmp" 2>/dev/null
        done
        if [ -s "$_vb.tmp" ]; then
            mv -f "$_vb.tmp" "$_vb" 2>/dev/null && {
                echo "baseline|$_vb" >> "$PATCH_DIR/known.list"
                ui_print "   · 已记录 VRR 亮度字段基线 → $_vb"
            }
        else
            rm -f "$_vb.tmp" 2>/dev/null
        fi
    fi
fi

# ══════════ 废弃键清理（v2.11.1）══════════════════════════════
# v2.9.2 移除了 CPU 频率限制功能（CPU_LIMIT_MODE / LIMIT_PERF_MHZ /
# LIMIT_PRIME_MHZ）。load_conf 对未知键是静默忽略（不报错、不影响启动），
# 但老用户从 v2.8.13~v2.9 升上来时，mode.conf 里若还留着这些键，会疑惑
# "我明明没开限频，怎么配置文件里还有"。这里在升级路径显式清掉并提示。
# 说明：正常「刷 zip 升级」会覆盖 mode.conf、废弃键本就会消失；这一段是
# 兜底「不刷包、手动同步脚本 / 从旧备份恢复」这类场景，成本极低。
_dep_keys="CPU_LIMIT_MODE LIMIT_PERF_MHZ LIMIT_PRIME_MHZ"
_dep_n=0
for _dep_k in $_dep_keys; do
    if grep -q "^$_dep_k=" "$module/mode.conf" 2>/dev/null; then
        sed -i "/^$_dep_k=/d" "$module/mode.conf" 2>/dev/null && _dep_n=$((_dep_n + 1))
    fi
done
[ "$_dep_n" -gt 0 ] && ui_print "   · 已清理 $_dep_n 个已废弃的 CPU 限频键（v2.9.2 起移除该功能）"

# ── 权限 ──────────────────────────────────────────────────────
chmod -R 0755 "$PATCH_DIR" 2>/dev/null
find "$PATCH_DIR" -type f -exec chmod 0644 {} \; 2>/dev/null
chmod 0755 "$module/service.sh" "$module/post-fs-data.sh" "$module/uninstall.sh" \
           "$module/action.sh" "$module/thermal_spoof.sh" \
           "$module/common/functions.sh" "$module/common/conflicts.sh" \
           "$module/webui_server.sh" "$module/webroot/cgi-bin/api.sh" 2>/dev/null
chmod 0644 "$module/module.prop" "$module/mode.conf" "$module/spoof.conf" \
           "$module/game_list.conf" "$module/protect_list.conf" \
           "$module/webroot/index.html" "$module/webroot/style.css" 2>/dev/null

ui_print ""
ui_print " ⚠ 风险提示："
ui_print "   · 移除温控后重载场景机身温度会显著升高"
ui_print "   · 可能加速电池老化，极端情况损伤硬件"
ui_print "   · SoC 硬件级过热保护无法被软件移除"
ui_print ""
ui_print " ⚠ 亮度/显示异常排查：WebUI 中依次关闭 PATCH_EXTRA → OPPO_SHELL_TEMP"
ui_print "   → HORAE_TESTMODE → DISABLE_ORMS，每改一项观察 10 分钟"
ui_print ""
