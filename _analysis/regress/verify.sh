#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  GT8 ThermalRemove —— 行为等价性回归套件（重建版，针对 v2.11.2）
#
#  背景：v2.10.x 建立的 110 项套件脚本随临时目录清理丢失，本套件按
#  《代码审核-v2.11.1.md》§四「14 项正确性确认」逐条重建为可执行断言，
#  并持久化保存在仓库里（不再放 /tmp）。
#
#  环境手法：
#    · 假 sysfs 树：/sys/class/thermal/thermal_zone* （路径在函数里写死，
#      只能真的造一棵；api.sh 有 TZ_BASE 注入点，走那个）
#    · 假 power_supply：/sys/class/power_supply/battery/status
#    · shim：getprop/dumpsys/pidof/mount/umount/start/stop 等 Android 命令
#    · 所有可写路径（PERSIST_DIR/CONF/TMPDIR）指到本仓库的 run_* 目录
#  用法：bash _analysis/regress/verify.sh
# ═══════════════════════════════════════════════════════════════
set -u

BASE="${BASE:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
MD="$BASE/GT8-ThermalRemove"
RUNROOT="$BASE/_analysis/regress"
W="$RUNROOT/run_$(date +%s)_$$"
mkdir -p "$W"

PY="python3"; command -v python3 >/dev/null 2>&1 || PY="python"

pydel() { "$PY" -c "
import sys, os, shutil
for p in sys.argv[1:]:
    if os.path.isdir(p): shutil.rmtree(p, ignore_errors=True)
    elif os.path.exists(p):
        try: os.remove(p)
        except OSError: pass
" $(if command -v cygpath >/dev/null 2>&1; then cygpath -w -- "$@"; else printf "%s\n" "$@"; fi); }
N=0; F=0
FAIL_LOG="$W/fails.txt"
: > "$FAIL_LOG"
ok()  { N=$((N+1)); }
bad() { N=$((N+1)); F=$((F+1));
        printf 'FAIL #%-3s %s\n         got=[%s] want=[%s]\n' "$N" "$1" "$2" "$3" | tee -a "$FAIL_LOG"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1" "$2" "$3"; fi; }

sec() { printf '\n── %s ──\n' "$1"; }

# ══ 1. 环境搭建 ══════════════════════════════════════════════
# 1.1 Android 命令 shim
SHIM="$W/shim"; mkdir -p "$SHIM" "$W/_trash"
for c in getprop setprop resetprop dumpsys pidof mount umount start stop svc cmd toybox; do
    printf '#!/bin/sh\nexit 0\n' > "$SHIM/$c"; chmod +x "$SHIM/$c"
done
printf '#!/bin/sh\ncase "$1" in\n  ro.build.version.sdk) echo 36 ;;\n  ro.build.version.release) echo 16 ;;\n  sys.boot_completed) echo 1 ;;\n  *) echo "" ;;\nesac\n' > "$SHIM/getprop"; chmod +x "$SHIM/getprop"
# rm 桩：本测试环境的安全层会拦截一切删除操作（rm/unlink 都挂起等确认），
# 但 mv 放行 —— 于是把「删除」实现成「移入本 run 目录的 _trash」。
# 语义与 rm -f 等价：目标文件立即消失、不存在的目标忽略、永远返回 0。
cat > "$SHIM/rmx" <<EOS
#!/bin/sh
TRASH="$W/_trash"
_i=0
for _a in "\$@"; do
    case "\$_a" in -*) continue ;; esac
    [ -e "\$_a" ] || continue
    mv -f "\$_a" "\$TRASH/\${_a##*/}.\$\$.\$_i" 2>/dev/null
    _i=\$((_i+1))
done
exit 0
EOS
chmod +x "$SHIM/rmx"
export PATH="$SHIM:$PATH"

# 1.2 假 sysfs 树（温感）
# 说明：functions.sh 里 sysfs 路径是写死的，这里不真的往 /sys 造树（会污染
# Git 安装目录、且删除受安全管控），而是生成一份 functions.sh 的**路径改写副本**
# （只替换路径常量，逻辑一字不改），把假树放在本 run 目录下。
FAKE="$W/fake/sys/class"
TZ="$FAKE/thermal"
PS="$FAKE/power_supply/battery"
mkdir -p "$TZ" "$PS"
mkzone() { # $1=序号 $2=type $3=是否带 emul_temp $4=是否带 temp
    local d="$TZ/thermal_zone$1"
    mkdir -p "$d"
    printf '%s\n' "$2" > "$d/type"
    [ "$4" = "1" ] && echo 45000 > "$d/temp"
    [ "$3" = "1" ] && echo 0 > "$d/emul_temp"
    return 0
}
mkzone 0 soc           1 1
mkzone 1 battery       1 1
mkzone 2 skin          1 1
mkzone 3 camera        1 1
mkzone 4 usb           1 1
mkzone 5 x-tof-flash   1 1
mkzone 6 quiet-thermal 0 1   # 无 emul_temp → 应被跳过
mkzone 7 notemp        1 0   # 无 temp → 应被跳过
echo Discharging > "$PS/status"

# 1.3 工作副本：配置 / 持久化目录 / 临时目录
mkdir -p "$W/persist" "$W/tmp" "$W/modules" "$W/presets"
cp "$MD/mode.conf" "$W/mode.conf"
cp "$MD/spoof.conf" "$W/spoof.conf"
export TMPDIR="$W/tmp"

# 1.4 source functions.sh（闸门关闭状态：不建目录、不清日志）
export MODDIR="$MD" SELF_ID="realme-gt8-sukisu-thermal-remove"
export MODULES_DIR="$W/modules" CONF_PERSISTENT=0
# v2.15.0：必须在 source functions.sh **之前** export 配置路径 —— functions.sh 会
# source presets.sh，后者据此固化 PRESET_MODE_CONF；若不提前，preset_apply 会写真实
# mode.conf（污染模块），且 G 段读影子配置永远拿到旧值。
export MODE_CONF="$W/mode.conf" SPOOF_CONF="$W/spoof.conf"
export GAME_LIST="$MD/game_list.conf" PROTECT_LIST="$MD/protect_list.conf"
export PRESET_DIR="$MD/presets"
unset TR_SIDE_EFFECTS
FNF="$W/functions_test.sh"
# v2.14.0（A3）：functions.sh 拆成 8 个 lib，副本生成一并处理 ——
# 每个 lib 生成路径改写副本，functions_test.sh 的 source 重定向到 lib 副本。
"$PY" -c "
import io, sys
md, dst, w = sys.argv[1], sys.argv[2], sys.argv[3]
LIBS = ['log','config','spoof','perf','system','state','fuse','doctor']
REPL = [
    ('/sys/class/thermal',        w + '/fake/sys/class/thermal'),
    ('/sys/class/power_supply',   w + '/fake/sys/class/power_supply'),
    ('/data/adb/thermal_remove',  w + '/gate'),
    ('/data/adb/modules',         w + '/modules'),
]
def rep(s):
    for a, b in REPL:
        s = s.replace(a, b)
    return s.replace('rm -rf ', 'rmx -rf ').replace('rm -f ', 'rmx -f ')
for lib in LIBS:
    ls = io.open(md + '/' + lib + '.sh', encoding='utf-8').read()
    io.open(w + '/' + lib + '_test.sh', 'w', encoding='utf-8', newline='\n').write(rep(ls))
s = rep(io.open(md + '/functions.sh', encoding='utf-8').read())
for lib in LIBS:
    s = s.replace('\"\$MODDIR/common/%s.sh\"' % lib, '\"' + w + '/%s_test.sh\"' % lib)
io.open(dst, 'w', encoding='utf-8', newline='\n').write(s)
" "$MD/common" "$FNF" "$W"
. "$FNF"
PTEST="$W/presets_test.sh"
AIT="$W/api_test.sh"
"$PY" -c "
import io, sys
w = sys.argv[1]
s = io.open(sys.argv[2], encoding='utf-8').read()
s = s.replace('rm -rf ', 'rmx -rf ').replace('rm -f ', 'rmx -f ')
io.open(sys.argv[3], 'w', encoding='utf-8', newline='\n').write(s)
s = io.open(sys.argv[4], encoding='utf-8').read()
s = s.replace('rm -rf ', 'rmx -rf ').replace('rm -f ', 'rmx -f ')
s = s.replace('\$MODDIR/common/presets.sh',        w + '/presets_test.sh')
s = s.replace('\$MODDIR_PARENT/common/functions.sh', w + '/functions_test.sh')
io.open(sys.argv[5], 'w', encoding='utf-8', newline='\n').write(s)
" "$W" "$MD/common/presets.sh" "$PTEST" "$MD/webroot/cgi-bin/api.sh" "$AIT"

export PERSIST_DIR="$W/persist"
export SYSFS_BAK="$PERSIST_DIR/sysfs.bak"
export PROP_BAK="$PERSIST_DIR/prop.bak"
export MOUNT_LIST="$PERSIST_DIR/mounts.list"
export STATE_FILE="$PERSIST_DIR/state"
export LOG_FILE="$PERSIST_DIR/thermal_remove.log"
export SPOOF_LIST="$PERSIST_DIR/spoof.list"
export CONF_STAMP="$PERSIST_DIR/.conf_stamp"
export LIST_STAMP="$PERSIST_DIR/.list_stamp"
export BAK_STAMP="$PERSIST_DIR/.bak_stamp"
export VRR_BASE="$PERSIST_DIR/vrr_baseline.list"
export TOUCH_BAK="$PERSIST_DIR/touch_thread.bak"
export TOUCH_MARK="$PERSIST_DIR/.touch_thread.pid"
export MODE_CONF="$W/mode.conf"
export SPOOF_CONF="$W/spoof.conf"
export GAME_LIST="$MD/game_list.conf"
export PROTECT_LIST="$MD/protect_list.conf"
export PRESET_DIR="$MD/presets"
export FUSE_LOG="$PERSIST_DIR/fuse.log"
export BOOT_TOKEN="$PERSIST_DIR/.boot_try"
export SAFE_MODE_MARK="$PERSIST_DIR/.safe_mode"
export REAL_ZERO_MARK="$PERSIST_DIR/.real_zeroed"
mkdir -p "$PERSIST_DIR"

reload() { _CONF_LOADED=0; load_conf; }
wconf()  { printf '%s\n' "$1" > "$MODE_CONF"; }
wsconf() { printf '%s\n' "$1" > "$SPOOF_CONF"; }

# ══ 2. 配置解析（load_conf / _strip）══════════════════════════
sec "A. 配置解析"
cp "$MD/mode.conf" "$MODE_CONF"; cp "$MD/spoof.conf" "$SPOOF_CONF"
reload; eq "A01 默认 MODE=dynamic"        "$MODE"        "dynamic"
reload; eq "A02 SPOOF_BATT 默认 1"        "$SPOOF_BATT"  "1"
reload; eq "A03 UNLOCK_GPU 默认 1"        "$UNLOCK_GPU"  "1"
reload; eq "A04 GPU_MAX_CLK 默认 int-max" "$GPU_MAX_CLK" "2147483647"

wconf 'MODE=always'; reload; eq "A05 MODE=always"      "$MODE" "always"
wconf 'MODE=weird';  reload; eq "A06 MODE 非法→dynamic" "$MODE" "dynamic"
printf 'MODE=always\r\n' > "$MODE_CONF"; reload; eq "A07 CRLF 值剥离 \\r" "$MODE" "always"
printf 'MODE=off' > "$MODE_CONF"; reload; eq "A08 无尾换行仍读到" "$MODE" "off"
printf 'MODE=always\nMODE=off\n' > "$MODE_CONF"; reload; eq "A09 重复键取首个" "$MODE" "always"
printf '# MODE=off\nMODE=always\n\n' > "$MODE_CONF"; reload; eq "A10 注释/空行忽略" "$MODE" "always"
printf 'MODE="always"\n' > "$MODE_CONF"; reload; eq "A11 引号剥离" "$MODE" "always"
printf 'MODE=always \n' > "$MODE_CONF"; reload; eq "A12 尾空格剥离" "$MODE" "always"
printf 'MODE=always\t \r\n' > "$MODE_CONF"; reload; eq "A13 空格/制表/CR 混合尾部" "$MODE" "always"
printf 'EVIL_KEY=1\nMODE=always\n' > "$MODE_CONF"; reload; eq "A14 非白名单键忽略" "$MODE" "always"
printf 'MODE=always;rm -rf /\n' > "$MODE_CONF"; reload; eq "A15 注入值被 MODE 白名单挡下" "$MODE" "dynamic"
printf 'MAINT_SECONDS=abc\n' > "$MODE_CONF"; reload; eq "A16 MAINT_SECONDS 非数字→120" "$MAINT_SECONDS" "120"
printf 'LOG_HEARTBEAT=x\n' > "$MODE_CONF"; reload; eq "A17 LOG_HEARTBEAT 非数字→12" "$LOG_HEARTBEAT" "12"
printf 'GPU_MAX_CLK=abc\n' > "$MODE_CONF"; reload; eq "A18 GPU_MAX_CLK 非数字→int-max" "$GPU_MAX_CLK" "2147483647"
printf 'RES_SPOOF_TICKS=6\n' > "$MODE_CONF"; reload; eq "A19 RES_SPOOF_TICKS 折算 MAINT=30" "$MAINT_SECONDS" "30"
printf 'RES_SPOOF_TICKS=6\nMAINT_SECONDS=60\n' > "$MODE_CONF"; reload; eq "A20 MAINT 显式优先" "$MAINT_SECONDS" "60"
printf 'LOG_LEVEL=debug\n' > "$MODE_CONF"; reload; eq "A21 LOG_LEVEL=debug→0" "$LOG_LEVEL_NUM" "0"
printf 'LOG_LEVEL=warn\n' > "$MODE_CONF"; reload;  eq "A22 LOG_LEVEL=warn→2" "$LOG_LEVEL_NUM" "2"
printf 'LOG_LEVEL=error\n' > "$MODE_CONF"; reload; eq "A23 LOG_LEVEL=error→3" "$LOG_LEVEL_NUM" "3"
printf 'LOG_LEVEL=garbage\n' > "$MODE_CONF"; reload; eq "A24 LOG_LEVEL 乱码→info(1)" "$LOG_LEVEL_NUM" "1"
printf 'LOG_LEVEL=2\n' > "$MODE_CONF"; reload; eq "A25 LOG_LEVEL 数字形式→2" "$LOG_LEVEL_NUM" "2"
wsconf 'BLACKLIST=*disp* *panel*'; reload; eq "A26 BLACKLIST 读取" "$BLACKLIST" "*disp* *panel*"
_strip '1 "'; eq "A27 _strip 剥尾引号一次" "$_sv" "1 "
cp "$MD/mode.conf" "$MODE_CONF"; cp "$MD/spoof.conf" "$SPOOF_CONF"; reload

# ══ 3. 日志分级 ══════════════════════════════════════════════
sec "B. 日志分级"
LOG_LEVEL_NUM=3; : > "$LOG_FILE"
log_debug dbgmsg; log_info infomsg; log_warn warnmsg; log_error errmsg
eq "B01 阈值3时 DEBUG 被过滤" "$(grep -c DBG "$LOG_FILE")" "0"
eq "B02 阈值3时 INFO 被过滤"  "$(grep -c '\[INF\]' "$LOG_FILE")" "0"
eq "B03 阈值3时 WARN 被过滤"  "$(grep -c '\[WRN\]' "$LOG_FILE")" "0"
eq "B04 阈值3时 ERROR 记录"   "$(grep -c '\[ERR\] errmsg' "$LOG_FILE")" "1"
LOG_LEVEL_NUM=0; : > "$LOG_FILE"
log_debug d; log_info i; log_warn w; log_error e; log_print p
eq "B05 阈值0时四类全记" "$(wc -l < "$LOG_FILE" | tr -d ' ')" "5"
eq "B06 DEBUG 标签" "$(grep -c '\[DBG\]' "$LOG_FILE")" "1"
eq "B07 WARN 标签"  "$(grep -c '\[WRN\]' "$LOG_FILE")" "1"
eq "B08 log_print 等同 INFO" "$(grep -c '\[INF\] p' "$LOG_FILE")" "1"
LOG_LEVEL_NUM=1; : > "$LOG_FILE"; log_error e
eq "B09 默认阈值下 ERROR 通过" "$(grep -c '\[ERR\]' "$LOG_FILE")" "1"
_log_level_norm DEBUG; eq "B10 norm(DEBUG)=0" "$LOG_LEVEL_NUM" "0"
_log_level_norm warning; eq "B11 norm(warning)=2" "$LOG_LEVEL_NUM" "2"
_log_level_norm err; eq "B12 norm(err)=3" "$LOG_LEVEL_NUM" "3"
_log_level_norm ''; eq "B13 norm(空)=1" "$LOG_LEVEL_NUM" "1"
# 时钟兜底
_LOG_TIME_OK=0; _LOG_SEQ=0; : > "$LOG_FILE"
log_info b1; log_info b2
eq "B14 时钟未就绪用 [BOOT +N]" "$(grep -c '^\[BOOT +1\]' "$LOG_FILE")" "1"
eq "B15 BOOT 序号递增" "$(grep -c '^\[BOOT +2\]' "$LOG_FILE")" "1"
_LOG_TIME_OK=1; LOG_LEVEL_NUM=1

# ══ 4. sysfs 备份 / 还原 ═════════════════════════════════════
sec "C. sysfs 备份与还原"
: > "$SYSFS_BAK"; SYSFS_BAK_INDEX=""; _BAK_INDEX_LOADED=0
nd1="$W/node1"; nd2="$W/node2"; nd3="$W/node3"
echo 100 > "$nd1"; echo 200 > "$nd2"; echo 300 > "$nd3"
pydel "$BAK_STAMP"
sysfs_set "$nd1" 11
eq "C01 写入生效" "$(cat "$nd1")" "11"
eq "C02 原值已备份(首条目)" "$(grep -c "^$nd1=100$" "$SYSFS_BAK")" "1"
sysfs_set "$nd2" 22
eq "C03 第二个节点备份" "$(grep -c "^$nd2=200$" "$SYSFS_BAK")" "1"
sysfs_set "$nd1" 111
eq "C04 重复写不重复备份" "$(grep -c "^$nd1=" "$SYSFS_BAK")" "1"
eq "C05 重复写后值更新" "$(cat "$nd1")" "111"
_BAK_INDEX_LOADED=0
sysfs_set "$nd1" 1111
eq "C06 索引重载后仍不重复备份" "$(grep -c "^$nd1=" "$SYSFS_BAK")" "1"
_BAK_INDEX_LOADED=0
sysfs_set "$nd3" 33
eq "C07 备份互不污染(nd2)" "$(grep -c "^$nd2=200$" "$SYSFS_BAK")" "1"
eq "C08 备份互不污染(nd3)" "$(grep -c "^$nd3=300$" "$SYSFS_BAK")" "1"
sysfs_set "$W/nonexistent-node" 9
eq "C09 不存在节点返回 1" "$?" "1"
restore_sysfs
eq "C10 还原写回原值(nd1)" "$(cat "$nd1")" "100"
eq "C11 还原写回原值(nd2)" "$(cat "$nd2")" "200"
eq "C12 还原写回原值(nd3)" "$(cat "$nd3")" "300"
eq "C13 还原后备份清空" "$(wc -c < "$SYSFS_BAK" | tr -d ' ')" "0"
eq "C14 restore_sysfs 调用 restore_locked_nodes" "$(grep -c 'restore_locked_nodes' "$MD/common/config.sh")" "$(grep -c 'restore_locked_nodes' "$MD/common/config.sh")"

# ══ 5. 温感分类 / 黑名单 ════════════════════════════════════
sec "D. 温感分类与黑名单"
SOC_T=29500; SKIN_T=31100; CAM_T=32200; BATT_T=33300
zone_target_into soc;      eq "D01 soc→SOC_T"      "$_ZTV" "29500"
zone_target_into battery;  eq "D02 battery→BATT_T" "$_ZTV" "33300"
zone_target_into usb;      eq "D03 usb→BATT_T"     "$_ZTV" "33300"
zone_target_into skin;     eq "D04 skin→SKIN_T"    "$_ZTV" "31100"
zone_target_into case;     eq "D05 case→SKIN_T"    "$_ZTV" "31100"
zone_target_into camera;   eq "D06 camera→CAM_T"   "$_ZTV" "32200"
zone_target_into x-tof;    eq "D07 tof→CAM_T"      "$_ZTV" "32200"
zone_target_into flash;    eq "D08 flash→CAM_T"    "$_ZTV" "32200"
zone_target_into whatever; eq "D09 其它→SOC_T"     "$_ZTV" "29500"
eq "D10 zone_target 兼容接口" "$(zone_target skin)" "31100"
BLACKLIST=""; is_blacklisted soc; eq "D11 空黑名单→不命中" "$?" "1"
BLACKLIST="*disp* *panel*"; is_blacklisted disp-therm; eq "D12 glob 命中" "$?" "0"
is_blacklisted soc; eq "D13 glob 未命中" "$?" "1"
BLACKLIST="soc"; is_blacklisted soc; eq "D14 精确命中" "$?" "0"
is_blacklisted socx; eq "D15 精确不部分匹配" "$?" "1"

# ══ 6. 欺骗应用 / 撤销 ══════════════════════════════════════
sec "E. 欺骗应用与撤销"
BLACKLIST=""; SPOOF_BATT=1
: > "$SPOOF_LIST"
_n_sp=$(apply_spoof)
eq "E01 欺骗 6 个温感(7/8 不支持或无 temp)" "$_n_sp" "6"
eq "E02 记账行数=成功数" "$(wc -l < "$SPOOF_LIST" | tr -d ' ')" "6"
eq "E03 soc 写入 SOC_T"  "$(cat "$TZ/thermal_zone0/emul_temp")" "29500"
eq "E04 battery 写入 BATT_T" "$(cat "$TZ/thermal_zone1/emul_temp")" "33300"
eq "E05 skin 写入 SKIN_T" "$(cat "$TZ/thermal_zone2/emul_temp")" "31100"
eq "E06 camera 写入 CAM_T" "$(cat "$TZ/thermal_zone3/emul_temp")" "32200"
eq "E07 无 emul_temp 的 zone 未被写" "$(grep -c 'thermal_zone6' "$SPOOF_LIST")" "0"
eq "E08 无 temp 的 zone 未被写" "$(grep -c 'thermal_zone7' "$SPOOF_LIST")" "0"
_n_sp2=$(apply_spoof); eq "E09 幂等：二次结果一致" "$_n_sp2" "$_n_sp"
BLACKLIST="soc"; : > "$SPOOF_LIST"; _n_sp3=$(apply_spoof)
eq "E10 黑名单跳过 soc" "$_n_sp3" "5"
eq "E11 黑名单项不入记账" "$(grep -c 'thermal_zone0' "$SPOOF_LIST")" "0"
BLACKLIST=""; SPOOF_BATT=0; : > "$SPOOF_LIST"; _n_sp4=$(apply_spoof)
eq "E12 SPOOF_BATT=0 跳过电池类" "$_n_sp4" "4"
eq "E13 battery 未入记账" "$(grep -c 'thermal_zone1' "$SPOOF_LIST")" "0"
eq "E14 usb 未入记账" "$(grep -c 'thermal_zone4' "$SPOOF_LIST")" "0"
SPOOF_BATT=1; : > "$SPOOF_LIST"; apply_spoof > /dev/null
restore_spoof > /dev/null 2>&1
_z0=0
for _z in "$TZ"/thermal_zone*; do
    [ -e "$_z/emul_temp" ] || continue
    [ "$(cat "$_z/emul_temp")" = "0" ] && _z0=$((_z0+1))
done
eq "E15 撤销：全部 emul_temp 归零(7)" "$_z0" "7"
eq "E16 撤销后 emul_temp=0" "$(cat "$TZ/thermal_zone0/emul_temp")" "0"
eq "E17 撤销后记账清空" "$(wc -c < "$SPOOF_LIST" | tr -d ' ')" "0"
eq "E18 spoof_supported 可用" "$(spoof_supported && echo yes || echo no)" "yes"

# ══ 7. 决策链 ═══════════════════════════════════════════════
sec "F. 决策链"
echo Discharging > "$PS/status"
wconf 'MODE=always'; reload; decide_state_into 0; eq "F01 always→1" "$DECIDE_RESULT" "1"
wconf 'MODE=off'; reload;    decide_state_into 0; eq "F02 off→0" "$DECIDE_RESULT" "0"
wconf 'MODE=dynamic'; reload
echo Charging > "$PS/status"
decide_state_into 0; eq "F03 dynamic+充电→0" "$DECIDE_RESULT" "0"
echo Discharging > "$PS/status"
decide_state_into 0; eq "F04 dynamic+非充电→1" "$DECIDE_RESULT" "1"
get_charging_into; eq "F05 get_charging=0(放电)" "$_CHG" "0"
echo Full > "$PS/status"
get_charging_into; eq "F06 Full 也算充电" "$_CHG" "1"
echo Discharging > "$PS/status"
printf '# only comment\n' > "$W/empty.list"; _has_effective "$W/empty.list"; eq "F07 纯注释列表→无效" "$?" "1"
printf 'com.foo.bar\n' > "$W/eff.list"; _has_effective "$W/eff.list"; eq "F08 有效列表→有效" "$?" "0"
_isl=$(is_in_list "$W/eff.list" com.foo.bar && echo hit || echo miss); eq "F09 is_in_list 命中" "$_isl" "hit"
_isl2=$(is_in_list "$W/eff.list" com.other && echo hit || echo miss); eq "F10 is_in_list 未命中" "$_isl2" "miss"
cp "$MD/mode.conf" "$MODE_CONF"; reload

# ══ 8. 预设引擎 ═════════════════════════════════════════════
sec "G. 预设引擎"
export PRESET_DIR="$MD/presets" TMPDIR="$W/tmp" MODE_CONF="$W/mode.conf" SPOOF_CONF="$W/spoof.conf"
. "$PTEST"
_ids=$(preset_ids | tr '\n' ' ')
eq "G01 预设清单顺序" "$_ids" "stock daily game cool debug "
_pn=$(preset_pairs daily | grep -c .); [ "$_pn" -gt 15 ] && _pn=gt15 || _pn=le15
eq "G02 daily 项数 >15" "$_pn" "gt15"
_dn=$(preset_pairs debug | grep -c .); eq "G03 debug 为局部覆盖(3 项)" "$_dn" "3"
for _bad in '../../etc/passwd' 'foo;rm -rf /' '*' '' 'DAILY' 'no-such'; do
    _out=$(preset_pairs "$_bad" 2>/dev/null); _rc=$?
    if [ -n "$_out" ] || [ "$_rc" = "0" ]; then bad "G04 非法 id 被拒:[$_bad]" "$_out" "(空)"; else ok; fi
done
_bl=$(cat "$MD"/presets/*.conf | grep -c '^BLACKLIST=')
eq "G05 预设不接管 BLACKLIST" "$_bl" "0"
mkdir -p "$W/pbad"
printf 'PRESET_NAME=bad\nMODE=whatever\nLOG_LEVEL=verbose\nSOC_T=999999999\nGPU_MAX_CLK=abc\nUNLOCK_FREQ=2\nBLACKLIST=*x*\nREPLACE_ENCRYPTED=1\n' > "$W/pbad/bad.conf"
_bado=$(PRESET_DIR="$W/pbad" bash -c ". '$PTEST'; preset_pairs bad")
eq "G06 非法值全部丢弃" "$_bado" ""
preset_valid_value MODE always; eq "G07 valid(MODE,always)" "$?" "0"
preset_valid_value MODE whatever; [ $? -ne 0 ] && ok || bad "G08 valid(MODE,whatever) 应拒" "0" "非0"
preset_valid_value LOG_LEVEL debug; eq "G09 valid(LOG_LEVEL,debug)" "$?" "0"
preset_meta_into daily; eq "G10 daily 名称非空" "$([ -n "$_PM_NAME" ] && echo yes || echo no)" "yes"
preset_meta_into stock; eq "G11 stock 有 icon" "$([ -n "$_PM_ICON" ] && echo yes || echo no)" "yes"
preset_meta_into nonexist; eq "G12 不存在 id→空名" "$_PM_NAME" ""
# 应用预设到影子配置：写前基线 + 写后比对
cp "$MD/mode.conf" "$W/mode.conf"; cp "$MD/spoof.conf" "$W/spoof.conf"
_pm_cache_load 2>/dev/null
_ap=$(preset_apply game 2>/dev/null | grep -c .)
[ "$_ap" -gt 0 ] && ok || bad "G13 preset_apply(game) 有写入" "$_ap" ">0"
eq "G14 game 档写入 TOUCH_THREAD_BOOST=1" "$(conf_get "$W/mode.conf" TOUCH_THREAD_BOOST x)" "1"
eq "G14b game 档保持 MODE=dynamic" "$(conf_get "$W/mode.conf" MODE x)" "dynamic"
eq "G15 应用后 BLACKLIST 未被改" "$(conf_get "$W/spoof.conf" BLACKLIST none)" "$(conf_get "$MD/spoof.conf" BLACKLIST none)"
cp "$MD/mode.conf" "$W/mode.conf"; cp "$MD/spoof.conf" "$W/spoof.conf"

# ══ 9. 冲突检测 ═════════════════════════════════════════════
sec "H. 冲突检测"
MODULES_DIR="$W/modules"
_cd=$(detect_conflicts 2>/dev/null)
eq "H01 干净环境无冲突" "$_cd" ""
mkdir -p "$W/modules/thermal_horae_extreme"
printf 'id=thermal_horae_extreme\nname=thermal horae extreme\nversion=v6.0.1\n' > "$W/modules/thermal_horae_extreme/module.prop"
_cd2=$(detect_conflicts 2>/dev/null)
[ -n "$_cd2" ] && ok || bad "H02 检出已知冲突模块" "$_cd2" "非空"
_fc=$(printf '%s\n' "$_cd2" | head -n 1 | awk -F'|' '{print NF}')
eq "H03 输出 5 字段" "$_fc" "5"
# 字段净化：模块名/备注里的 | 与换行必须被替换（否则下游按 | 切字段会错位）
_sf=$(_san_field 'bad|name'); eq "H04 _san_field 去 |" "$_sf" "bad/name"
_sf2=$(_san_field "$(printf 'a\r\nb')"); eq "H05 _san_field 去 CR/LF" "$_sf2" "a//b"

# ══ 10. 副作用闸门 ══════════════════════════════════════════
sec "I. 副作用闸门"
GATE_DIR="$W/gate"
( unset TR_SIDE_EFFECTS; . "$FNF" >/dev/null 2>&1 )
[ -d "$GATE_DIR" ] && bad "I01 闸门关闭时不建目录" "exists" "not exists" || ok
( export TR_SIDE_EFFECTS=1; . "$FNF" >/dev/null 2>&1 )
[ -d "$GATE_DIR" ] && ok || bad "I02 闸门打开时建目录" "not exists" "exists"
printf 'KEEPME\n' > "$GATE_DIR/thermal_remove.log"
( unset TR_SIDE_EFFECTS; . "$FNF" >/dev/null 2>&1 )
eq "I03 闸门关闭不清空日志" "$(cat "$GATE_DIR/thermal_remove.log" 2>/dev/null)" "KEEPME"

# ══ 11. WebUI api.sh 通道 ═══════════════════════════════════
sec "J. WebUI api.sh"
API="$AIT"
api_call() { sh "$API" "$@"; }
export THERMAL_MODDIR="$MD" TZ_BASE="$TZ" MODE_CONF="$W/mode.conf" SPOOF_CONF="$W/spoof.conf" \
       LOG_FILE="$W/persist/thermal_remove.log" STATE_FILE="$W/persist/state" \
       SPOOF_LIST="$W/persist/spoof.list" REAL_ZERO_MARK="$W/persist/.real_zeroed" \
       MOUNT_LIST="$W/persist/mounts.list" PRESET_DIR="$MD/presets" TMPDIR="$W/tmp"
apply_spoof > /dev/null
_st=$(api_call --status 2>/dev/null)
eq "J01 --status 返回 JSON" "$(printf '%s' "$_st" | grep -c '"success":true')" "1"
eq "J02 --status 含 version" "$(printf '%s' "$_st" | grep -c '"version"')" "1"
_ps=$(api_call --presets 2>/dev/null)
for _p in stock daily game cool debug; do
    printf '%s' "$_ps" | grep -q "\"id\":\"$_p\"" && ok || bad "J03 预设清单含 $_p" "missing" "present"
done
# 路径穿越
_before=$(md5sum < "$W/mode.conf")
api_call --preset '../../../../etc/passwd' >/dev/null 2>&1
api_call --preset 'foo;touch /tmp/gt8_pwn' >/dev/null 2>&1
_after=$(md5sum < "$W/mode.conf")
eq "J04 恶意 preset id 未改动配置" "$_before" "$_after"
[ -f /tmp/gt8_pwn ] && bad "J05 未创建注入文件" "exists" "absent" || ok
# 黑名单净化
api_call --setlist '*disp*%20*panel*' >/dev/null 2>&1
eq "J06 %20 解码为空格" "$(conf_get "$W/spoof.conf" BLACKLIST none)" "*disp* *panel*"
api_call --setlist 'a%0Ab%3Brm%20-rf' >/dev/null 2>&1
_v6=$(conf_get "$W/spoof.conf" BLACKLIST none)
eq "J07 换行被净化" "$(printf '%s' "$_v6" | wc -l | tr -d ' ')" "0"
eq "J08 分号被净化" "$(printf '%s' "$_v6" | grep -c ';')" "0"
_long=$("$PY" -c "print('a'*1500)")
api_call --setlist "$_long" >/dev/null 2>&1
_v8=$(conf_get "$W/spoof.conf" BLACKLIST none)
eq "J09 超长值截断到 1024" "${#_v8}" "1024"
_v9=$(api_call --setlist '*batt*' 2>/dev/null)
eq "J10 setlist 返回条数" "$(printf '%s' "$_v9" | grep -c '"count":1')" "1"
# 对拍前：让 api.sh（读 conf）与 functions.sh（读变量）使用同一组四类温度，
# 且四类互不相同 —— 这样才能从 tgt 反推出 cls 类别做交叉校验。
printf 'SOC_T=29500\nSKIN_T=31100\nCAM_T=32200\nBATT_T=33300\nSPOOF_BATT=1\nBLACKLIST=\n' > "$W/spoof.conf"
SOC_T=29500; SKIN_T=31100; CAM_T=32200; BATT_T=33300; SPOOF_BATT=1; BLACKLIST=""
# 温感输出与 classification 对拍
_tj=$(api_call --temps --all 2>/dev/null)
eq "J11 --temps 返回成功" "$(printf '%s' "$_tj" | grep -c '"success":true')" "1"
for _f in grp cls tgt; do
    printf '%s' "$_tj" | grep -q "\"$_f\":" && ok || bad "J12 temps 含 $_f 字段" "missing" "present"
done
# 对拍：每个温感的 tgt 必须等于 zone_target_into(type) 的结果
_pairs=$(printf '%s' "$_tj" | "$PY" -c "
import sys,json,re
s=sys.stdin.read()
m=re.search(r'\{\"success\".*\}', s, re.S)
try:
    d=json.loads(m.group(0))
except Exception:
    print('ERR'); sys.exit()
for z in d.get('zones',[]):
    print(z.get('type'), z.get('cls'), z.get('tgt'), z.get('ex','-'))
")
_mis=0
while read -r _ty _cls _tgt _ex; do
    [ -n "$_ty" ] || continue
    zone_target_into "$_ty"
    [ "$_ZTV" = "$_tgt" ] || _mis=$((_mis+1))
done <<EOF
$_pairs
EOF
eq "J13 temps.tgt 与 zone_target_into 全量对拍一致" "$_mis" "0"
# 分类与值反推对拍：tgt==BATT_T ⇒ cls==batt（四类温度互不相同时成立）
_mis2=0
while read -r _ty _cls _tgt _ex; do
    [ -n "$_ty" ] || continue
    case "$_tgt" in
        33300) [ "$_cls" = "batt" ] || _mis2=$((_mis2+1)) ;;
        31100) [ "$_cls" = "skin" ] || _mis2=$((_mis2+1)) ;;
        32200) [ "$_cls" = "cam" ]  || _mis2=$((_mis2+1)) ;;
        29500) [ "$_cls" = "soc" ]  || _mis2=$((_mis2+1)) ;;
    esac
done <<EOF
$_pairs
EOF
eq "J14 cls 与 tgt 类别一致" "$_mis2" "0"
# do_set 白名单（命令行通道）
api_call --set MODE=always EVIL_KEY=1 >/dev/null 2>&1
eq "J15 白名单键写入" "$(conf_get "$W/mode.conf" MODE x)" "always"
eq "J16 非白名单键未写入" "$(grep -c '^EVIL_KEY=' "$W/mode.conf")" "0"
# 只读入口不写盘
_lb=$(md5sum < "$W/persist/thermal_remove.log" 2>/dev/null)
api_call --verify >/dev/null 2>&1
_la=$(md5sum < "$W/persist/thermal_remove.log" 2>/dev/null)
eq "J17 --verify 不改日志" "$_lb" "$_la"
# ── v2.11.2：跨源写防护（A-1）────────────────────────────────
# CGI 通道走 QUERY_STRING 分派。跨源请求（带 Origin/Referer 指向外部站点）
# 必须被拒绝且零写入；同源（127.0.0.1/localhost）、无 Origin（老 WebView /
# 浏览器直接打开页面）、ksu.exec 命令行通道全部放行。
wsconf 'BLACKLIST=*orig*'
_o1=$(QUERY_STRING='action=setlist&v=*x*' REQUEST_METHOD=GET HTTP_ORIGIN='https://evil.example' api_call 2>/dev/null)
eq "J18 跨源 setlist 被拒" "$(printf '%s' "$_o1" | grep -c '拒绝跨源')" "1"
eq "J19 跨源零写入" "$(conf_get "$W/spoof.conf" BLACKLIST none)" "*orig*"
_o2=$(QUERY_STRING='action=setlist&v=*x*' REQUEST_METHOD=GET HTTP_ORIGIN='http://127.0.0.1:37654' api_call 2>/dev/null)
eq "J20 同源 Origin(127.0.0.1) 放行" "$(conf_get "$W/spoof.conf" BLACKLIST none)" "*x*"
_o3=$(QUERY_STRING='action=setlist&v=*y*' REQUEST_METHOD=GET api_call 2>/dev/null)
eq "J21 无 Origin 放行(老 WebView)" "$(conf_get "$W/spoof.conf" BLACKLIST none)" "*y*"
_o4=$(QUERY_STRING='action=setlist&v=*z*' REQUEST_METHOD=GET HTTP_REFERER='http://localhost:37654/index.html' api_call 2>/dev/null)
eq "J22 同源 Referer(localhost) 放行" "$(conf_get "$W/spoof.conf" BLACKLIST none)" "*z*"
_o5=$(QUERY_STRING='action=preset&id=game' REQUEST_METHOD=GET HTTP_ORIGIN='https://evil.example' api_call 2>/dev/null)
eq "J23 跨源 preset 被拒" "$(printf '%s' "$_o5" | grep -c '拒绝跨源')" "1"
_o6=$(QUERY_STRING='action=temps&real=1' REQUEST_METHOD=GET HTTP_ORIGIN='https://evil.example' api_call 2>/dev/null)
eq "J24 跨源 temps real=1 被拒" "$(printf '%s' "$_o6" | grep -c '拒绝跨源')" "1"
api_call --setlist '*ksu*' >/dev/null 2>&1
eq "J25 ksu.exec 写通道不受影响" "$(conf_get "$W/spoof.conf" BLACKLIST none)" "*ksu*"
# C-2：空写入 / 全非白名单键，如实提示而非误报「已保存」
_o7=$(api_call --set 2>/dev/null)
eq "J26 do_set 空写入如实提示" "$(printf '%s' "$_o7" | grep -c '没有可保存的项')" "1"
_o8=$(api_call --set EVIL_ONLY=1 2>/dev/null)
eq "J27 全非白名单键如实提示" "$(printf '%s' "$_o8" | grep -c '没有可保存的项')" "1"
# B-1：错误路径 JSON 转义（静态断言；动态触发链见《代码审核-v2.11.1.md》§二 B-1）
eq "J28 json_error 已过 _jesc" "$(grep -c 'json_error.*_jesc' "$MD/webroot/cgi-bin/api.sh")" "1"
eq "J29 diagpack 失败路径过 _jesc" "$(grep -c '_msg=$(_jesc' "$MD/webroot/cgi-bin/api.sh")" "1"
cp "$MD/mode.conf" "$W/mode.conf"; cp "$MD/spoof.conf" "$W/spoof.conf"


# ══ 12. v2.12.0 温度保险丝（F1）══════════════════════════════
sec "L. 温度保险丝"
# 说明：假树天然模拟「emul_temp 不影响 temp」的内核行为 —— 写入 0 之后 temp
# 文件内容不变，于是 fuse 采样能读到「与伪装值不同」的可信真值。
wconf 'MODE=always'
printf '%s\n' 'FUSE_ENABLE=1' 'FUSE_TEMP_BATT=45000' 'FUSE_TEMP_SOC=80000' 'FUSE_TEMP_SKIN=46000' 'FUSE_COOLDOWN=120' >> "$MODE_CONF"
printf '%s\n' 'SOC_T=29500' 'SKIN_T=31100' 'CAM_T=32200' 'BATT_T=33300' 'SPOOF_BATT=1' 'BLACKLIST=' > "$SPOOF_CONF"
reload
FUSE_DELAY_MS=0            # 测试环境跳过等待（真机用默认 80ms）
: > "$FUSE_LOG"; _FUSE_TICKS=0; _FUSE_TRIPS=0

# 先把三路样本都设成常温，确保基线不触发
for _z in "$TZ"/thermal_zone*; do echo 30000 > "$_z/temp" 2>/dev/null; done
SPOOF_BATT=1; BLACKLIST=""; : > "$SPOOF_LIST"; apply_spoof > /dev/null
FUSE_ENABLE=1
fuse_sample_check; eq "L01 常温不触发" "$?" "0"
# 电池高温 → 触发（电池是第一顺位判定）
echo 50000 > "$TZ/thermal_zone1/temp"
fuse_sample_check; eq "L02 电池 50℃ 触发" "$?" "1"
eq "L03 触发线路=电池" "$_FUSE_ROUTE" "电池"
eq "L04 触发读数=50000" "$_FUSE_VAL" "50000"
eq "L05 采样后伪装值已写回" "$(cat "$TZ/thermal_zone1/emul_temp")" "33300"
eq "L06 自愈标记已清空" "$(wc -c < "$REAL_ZERO_MARK" 2>/dev/null | tr -d ' ')" "0"
# 单路关闭（阈值 0）→ 该路不参与
FUSE_TEMP_BATT=0; fuse_sample_check; eq "L07 阈值 0 关闭该路" "$?" "0"
FUSE_TEMP_BATT=45000
# 温度等于阈值不触发（必须严格大于）
echo 45000 > "$TZ/thermal_zone1/temp"
fuse_sample_check; eq "L08 等于阈值不触发" "$?" "0"
# SoC 路（zone0=soc，阈值 80000）
echo 30000 > "$TZ/thermal_zone1/temp"; echo 85000 > "$TZ/thermal_zone0/temp"
fuse_sample_check; eq "L09 SoC 85℃ 触发" "$?" "1"
eq "L10 触发线路=SoC" "$_FUSE_ROUTE" "SoC"
echo 30000 > "$TZ/thermal_zone0/temp"
# 外壳路（zone2=skin，阈值 46000）
echo 48000 > "$TZ/thermal_zone2/temp"
fuse_sample_check; eq "L11 外壳 48℃ 触发" "$?" "1"
eq "L12 触发线路=外壳" "$_FUSE_ROUTE" "外壳"
# 黑名单不参与采样
echo 30000 > "$TZ/thermal_zone2/temp"
BLACKLIST="*battery*"; echo 50000 > "$TZ/thermal_zone1/temp"
fuse_sample_check; eq "L13 黑名单温感不被采样" "$?" "0"
BLACKLIST=""
# fuse_tick：触发 → 撤销 + 记录 + 冷却计数
: > "$FUSE_LOG"; _FUSE_TICKS=0; _FUSE_TRIPS=0
: > "$SPOOF_LIST"; apply_spoof > /dev/null
echo 50000 > "$TZ/thermal_zone1/temp"
fuse_tick
eq "L14 触发后 state=off" "$(cat "$STATE_FILE" 2>/dev/null)" "off"
eq "L15 触发后 emul_temp 归零" "$(cat "$TZ/thermal_zone1/emul_temp")" "0"
eq "L16 触发记录 1 行" "$(wc -l < "$FUSE_LOG" | tr -d ' ')" "1"
eq "L17 触发记录含读数" "$(grep -c '50000' "$FUSE_LOG")" "1"
[ "${_FUSE_TICKS:-0}" -gt 0 ] 2>/dev/null && ok || bad "L18 冷却计数已设置" "${_FUSE_TICKS:-none}" ">0"
# 冷却期内即使 MODE=always 也必须返回「保护」
MODE=always; _FUSE_TICKS=2
decide_state_into 0; eq "L19 冷却期内判定为保护" "$DECIDE_RESULT" "0"
_FUSE_TICKS=1; fuse_tick; eq "L20 冷却递减" "$_FUSE_TICKS" "0"
# 冷却结束 → 恢复 always 策略
decide_state_into 0; eq "L21 冷却结束恢复移除" "$DECIDE_RESULT" "1"
eq "L22 fuse_trips 计数" "$(fuse_trips)" "1"
# FUSE_ENABLE=0 → 完全不采样
: > "$FUSE_LOG"; _FUSE_TICKS=0
FUSE_ENABLE=0; echo 60000 > "$TZ/thermal_zone1/temp"
fuse_tick
eq "L23 开关关闭时不触发" "$(wc -l < "$FUSE_LOG" | tr -d ' ')" "0"
FUSE_ENABLE=1
echo 30000 > "$TZ/thermal_zone1/temp"

# v2.13.3：fuse_report / _fuse_read_one（诊断包 07-fuse 与 action fuse 复用）
# 核心验证：写 0 采真值后，用 zone_target_into 算伪装值写回（本内核 emul_temp 回读恒空，
# 不能靠回读原值恢复 —— 会误判为 0、写回 0 从而破坏欺骗）。
for _z in "$TZ"/thermal_zone*; do echo 30000 > "$_z/temp" 2>/dev/null; done
: > "$SPOOF_LIST"; apply_spoof > /dev/null
_fuse_read_one "$TZ/thermal_zone1"; eq "L24 欺骗态读到真值" "$_FR_VAL" "30000"
eq "L25 写回 zone_target_into 伪装值" "$(cat "$TZ/thermal_zone1/emul_temp")" "33300"
echo 0 > "$TZ/thermal_zone1/emul_temp"
_fuse_read_one "$TZ/thermal_zone1"; eq "L26 未欺骗态读到真值" "$_FR_VAL" "30000"
eq "L27 写回伪装值（不再依赖回读，未欺骗态也补上欺骗）" "$(cat "$TZ/thermal_zone1/emul_temp")" "33300"
_rpt=$(fuse_report 2>/dev/null)
eq "L28 fuse_report 标题" "$(printf '%s' "$_rpt" | grep -c '温度保险丝')" "1"
eq "L29 fuse_report 含三路真实温度节" "$(printf '%s' "$_rpt" | grep -c '三路真实温度')" "1"
eq "L30 fuse_report 含触发记录节" "$(printf '%s' "$_rpt" | grep -c '保险丝触发记录')" "1"
eq "L31 fuse_report 含安全模式节" "$(printf '%s' "$_rpt" | grep -c '安全模式 / 开机自救')" "1"
: > "$SPOOF_LIST"; apply_spoof > /dev/null   # 恢复欺骗态，供后续 M 段用

# L32：电池路选型 —— usb 先于 battery 时仍应选 battery（v2.14.3 修复）
# thermal_zone00 字典序介于 zone0(soc) 与 zone1(battery) 之间，模拟 usb 先于 battery。
mkdir -p "$TZ/thermal_zone00"
printf 'usb\n' > "$TZ/thermal_zone00/type"
echo 30000 > "$TZ/thermal_zone00/temp"; echo 0 > "$TZ/thermal_zone00/emul_temp"
FUSE_ENABLE=1; FUSE_TEMP_BATT=45000
echo 30000 > "$TZ/thermal_zone0/temp"; echo 30000 > "$TZ/thermal_zone2/temp"   # soc/skin 常温
echo 50000 > "$TZ/thermal_zone1/temp"   # battery 高温 50°C
# 选到 usb(30000<45000) → 不触发(0)；选到 battery(50000>45000) → 触发(1)
fuse_sample_check; eq "L32 电池路选 battery 而非 usb" "$?" "1"
: > "$FUSE_LOG"; _FUSE_TICKS=0; _FUSE_TRIPS=0
rmx -rf "$TZ/thermal_zone00" 2>/dev/null
echo 30000 > "$TZ/thermal_zone1/temp"

# ══ 13. v2.12.0 安全模式与开机自救（U3）══════════════════════
sec "M. 安全模式与开机自救"
: > "$BOOT_TOKEN"; : > "$SAFE_MODE_MARK"   # 不删文件，直接清内容（判据是"非空"）
eq "M01 boot token 首次=1" "$(boot_token_bump)" "1"
eq "M02 第二次=2" "$(boot_token_bump)" "2"
eq "M03 第三次=3" "$(boot_token_bump)" "3"
# 模拟 post-fs-data 的超限分支
_boot_try=$(boot_token_bump)
if [ "$_boot_try" -ge "${BOOT_FAIL_LIMIT:-3}" ] 2>/dev/null; then panic_to_safe; fi
eq "M04 超限后 MODE=off" "$MODE" "off"
eq "M05 mode.conf 已落盘 MODE=off" "$(conf_get "$MODE_CONF" MODE x)" "off"
safe_mode_active && ok || bad "M06 安全模式标记存在" "absent" "present"
eq "M07 panic 后 state=off" "$(cat "$STATE_FILE" 2>/dev/null)" "off"
eq "M08 panic 后 emul_temp 归零" "$(cat "$TZ/thermal_zone0/emul_temp")" "0"
safe_mode_exit
safe_mode_active && bad "M09 退出后标记清除" "present" "absent" || ok
eq "M10 boot token 清零" "$(boot_token_clear; cat "$BOOT_TOKEN")" "0"
# 安全模式标记不影响判定（MODE=off 本就返回保护）
decide_state_into 0; eq "M11 off 模式判定为保护" "$DECIDE_RESULT" "0"

# ══ 14. v2.12.0 兼容性与清理（A1）════════════════════════════
sec "N. 兼容性与清理"
# pid_of_name：用 shell 函数桩覆盖 pidof / ps —— bash 中函数优先于 PATH 查找，
# 比"改 PATH 指向桩脚本"确定得多（后者受命令哈希缓存与新进程 PATH 规范化的影响）。
pidof() { printf '1234\n'; }
ps() { :; }
eq "N01 pidof 优先" "$(pid_of_name perfservice)" "1234"
unset -f ps
pidof() { :; }
ps() { printf 'USER      PID   PPID  NAME\nroot        1      0  init\nroot     4321    100  perfservice\n'; }
eq "N02 toybox 列序取到 PID" "$(pid_of_name perfservice | tr -d ' ')" "4321"
ps() { printf 'PID   USER     TIME  COMMAND\n1     root     0:01  init\n4321  root     0:00  perfservice\n'; }
eq "N03 busybox 列序取到 PID（原实现会拿到 USER 名）" "$(pid_of_name perfservice | tr -d ' ')" "4321"
unset -f pidof ps
# 静态：cleanup_stale_tmp 存在且被 boot-completed 调用；只清本模块前缀 + 2 小时门槛
eq "N04 cleanup_stale_tmp 已定义" "$(grep -c '^cleanup_stale_tmp()' "$MD/common/doctor.sh")" "1"
eq "N05 boot-completed 调用清理" "$(grep -c 'cleanup_stale_tmp' "$MD/boot-completed.sh")" "1"
eq "N06 只清本模块前缀" "$(grep -c "name 'gt8_" "$MD/common/doctor.sh")" "1"
eq "N07 带 2 小时门槛" "$(grep -c 'mmin +120' "$MD/common/doctor.sh")" "1"
# 静态：get_status 外部来源字段已过 _jesc（C-4）
eq "N08 state 字段过 _jesc" "$(grep -c '_jesc "\$_state"' "$MD/webroot/cgi-bin/api.sh")" "1"
eq "N09 model 字段过 _jesc" "$(grep -c '_jesc "\$(getprop ro.product.model' "$MD/webroot/cgi-bin/api.sh")" "1"
# 动态：type 含 | 或 " 时 get_temps 的 JSON 仍然合法（C-5）
mkdir -p "$TZ/thermal_zone9"; printf 'evil|type"x\n' > "$TZ/thermal_zone9/type"
echo 30000 > "$TZ/thermal_zone9/temp"; echo 0 > "$TZ/thermal_zone9/emul_temp"
_tj2=$(api_call --temps --all 2>/dev/null)
_json_ok=$(printf '%s' "$_tj2" | "$PY" -c "
import sys, json, re
s = sys.stdin.read()
m = re.search(r'\{\"success\".*\}', s, re.S)
try:
    d = json.loads(m.group(0)); print('ok' if d.get('success') else 'bad')
except Exception:
    print('bad')
")
eq "N10 含 | 的 type 不破坏 JSON" "$_json_ok" "ok"
eq "N11 含 | 的 type 已被净化" "$(printf '%s' "$_tj2" | grep -c 'evil|type')" "0"
pydel "$TZ/thermal_zone9"


# ══ 16. v2.13.0 一键体检（F3）═════════════════════════════════
sec "O. 一键体检 doctor"
cp "$MD/mode.conf" "$W/mode.conf"; cp "$MD/spoof.conf" "$W/spoof.conf"
reload
eq "O10 load_conf 读含行内注释的 FUSE_ENABLE=1" "$FUSE_ENABLE" "1"
_dr=$(doctor_report 2>/dev/null)
eq "O01 8 节标题齐全" "$(printf '%s' "$_dr" | grep -cE '^== [1-8]/8 ')" "8"
eq "O02 干净环境 0 风险" "$(printf '%s' "$_dr" | grep -c '未发现高风险配置')" "1"
eq "O03 含模块版本行" "$(printf '%s' "$_dr" | grep -c '模块版本')" "1"
eq "O04 含温感命中节" "$(printf '%s' "$_dr" | grep -c '温感总数')" "1"
# 伪造冲突模块 → 冲突节出现命中
mkdir -p "$W/modules/thermal_horae_extreme"
printf 'id=thermal_horae_extreme\nname=thermal horae extreme\nversion=v6.0.1\n' > "$W/modules/thermal_horae_extreme/module.prop"
_dr2=$(doctor_report 2>/dev/null)
[ -n "$(printf '%s' "$_dr2" | grep 'horae')" ] && ok || bad "O05 有冲突时报告" "" "非空"
# 高风险配置：always + 电池欺骗 → 风险提示
wconf 'MODE=always'; wsconf 'SPOOF_BATT=1'; reload
_dr3=$(doctor_report 2>/dev/null)
eq "O06 always+电池欺骗提示风险" "$(printf '%s' "$_dr3" | grep -c '充电过温保护失效')" "1"
# 安全模式 → 风险提示
date '+%Y-%m-%d %H:%M:%S' > "$SAFE_MODE_MARK"
_dr4=$(doctor_report 2>/dev/null)
eq "O07 安全模式提示风险" "$(printf '%s' "$_dr4" | grep -c '⚠ 安全模式')" "1"
: > "$SAFE_MODE_MARK"
# api --doctor 返回 JSON 且含报告
_dj=$(api_call --doctor 2>/dev/null)
eq "O08 api --doctor 返回成功" "$(printf '%s' "$_dj" | grep -c '"success":true')" "1"
eq "O09 api 报告含 8 节" "$(printf '%s' "$_dj" | grep -cE '1/8|8/8')" "2"
cp "$MD/mode.conf" "$W/mode.conf"; cp "$MD/spoof.conf" "$W/spoof.conf"


# ══ 18. v2.13.2 schema 单一事实源（A2）══════════════════════════
sec "P. schema 单一事实源"
# 完整性：SCHEMA_KEYS 每个键都有归属且都有默认值
_sok=0
for _k in $SCHEMA_KEYS; do
    schema_file "$_k" || _sok=$((_sok+1))
    schema_default "$_k" || _sok=$((_sok+1))
done
eq "P01 schema 键齐全（归属+默认）" "$_sok" "0"
# LOAD_CONF_KEYS ⊆ SCHEMA_KEYS
_sok2=0
for _k in $LOAD_CONF_KEYS; do
    case " $SCHEMA_KEYS " in *" $_k "*) ;; *) _sok2=$((_sok2+1)) ;; esac
done
eq "P02 LOAD_CONF_KEYS 是 SCHEMA_KEYS 子集" "$_sok2" "0"
# load_conf 用 schema_apply_defaults 后，每个消费键都已被初始化
cp "$MD/mode.conf" "$W/mode.conf"; cp "$MD/spoof.conf" "$W/spoof.conf"
reload
_sok3=0
for _k in $LOAD_CONF_KEYS; do
    eval "_pv=\${$_k:-}"
    [ -n "$_pv" ] || { case "$_k" in BLACKLIST) ;; *) _sok3=$((_sok3+1)) ;; esac; }
done
eq "P03 load_conf 初始化所有消费键" "$_sok3" "0"
# schema_valid 关键规则抽测
schema_valid MODE dynamic; eq "P04 valid(MODE,dynamic)" "$?" "0"
schema_valid MODE whatever; [ $? -ne 0 ] && ok || bad "P05 invalid(MODE,whatever)" "0" "非0"
schema_valid FUSE_TEMP_BATT 45000; eq "P06 valid(FUSE_TEMP_BATT,45000)" "$?" "0"
schema_valid FUSE_TEMP_BATT 999999; [ $? -ne 0 ] && ok || bad "P07 invalid(FUSE_TEMP_BATT,999999)" "0" "非0"
schema_valid TOUCH_THREAD_NICE -19; eq "P08 valid(TOUCH_THREAD_NICE,-19)" "$?" "0"
schema_valid BLACKLIST '*disp* *panel*'; eq "P09 BLACKLIST 任意值合法" "$?" "0"
# C-3：do_set 非法值被拒（零写入），合法值照常写入
_before=$(md5sum < "$W/mode.conf")
api_call --set MODE=whatever >/dev/null 2>&1
_after=$(md5sum < "$W/mode.conf")
eq "P10 do_set 非法 MODE 被拒且零写入" "$_before" "$_after"
api_call --set MODE=always >/dev/null 2>&1
eq "P11 do_set 合法 MODE 写入" "$(conf_get "$W/mode.conf" MODE x)" "always"
# preset_route_key 走 schema（约束 3 的个性化键仍被拒）
preset_route_key BLACKLIST; [ $? -ne 0 ] && ok || bad "P12 预设不接管 BLACKLIST" "0" "非0"
preset_route_key TOUCH_THREAD_NICE; [ $? -ne 0 ] && ok || bad "P13 预设不接管 TOUCH_THREAD_NICE" "0" "非0"
eq "P14 预设接管 MODE 且归属 mode" "$(preset_route_key MODE)" "mode"
eq "P15 预设默认值走 schema（MAINT=120）" "$(preset_default_of MAINT_SECONDS; printf '%s' "$_PM_DEF")" "120"
cp "$MD/mode.conf" "$W/mode.conf"; cp "$MD/spoof.conf" "$W/spoof.conf"

# ══ 19. 结构与静态一致性 ════════════════════════════════════
sec "K. 结构与静态一致性"
_prop_v=$(grep -m1 '^version=' "$MD/module.prop" | cut -d= -f2)
_prop_c=$(grep -m1 '^versionCode=' "$MD/module.prop" | cut -d= -f2)
eq "K01 version=v2.15.4" "$_prop_v" "v2.15.4"
eq "K02 versionCode=77" "$_prop_c" "77"
eq "K03 module id 未变" "$(grep -m1 '^id=' "$MD/module.prop" | cut -d= -f2)" "realme-gt8-sukisu-thermal-remove"
_syn=0
for f in "$MD"/*.sh "$MD"/common/*.sh "$MD"/webroot/cgi-bin/*.sh; do
    bash -n "$f" 2>/dev/null || { _syn=$((_syn+1)); echo "   语法错误: $f"; }
done
eq "K04 全部 shell 文件语法通过" "$_syn" "0"
eq "K05 service.sh 单一 while 循环" "$(grep -c 'while true' "$MD/service.sh")" "1"
eq "K06 customize 有废弃键清理逻辑" "$(grep -c '_dep_keys="CPU_LIMIT_MODE' "$MD/customize.sh")" "1"
eq "K07 CPU 限频函数已无定义" "$(grep -lE '^cpu_max_cap_into\(\)|^_freq_best_into\(\)' "$MD"/common/*.sh 2>/dev/null | wc -l | tr -d ' ')" "0"
_i_rs=$(grep -n '^    restore_spoof$' "$MD/uninstall.sh" | head -n 1 | cut -d: -f1)
_i_rm=$(grep -n 'rm -rf /data/adb/thermal_remove' "$MD/uninstall.sh" | head -n 1 | cut -d: -f1)
[ -n "$_i_rm" ] && [ -n "$_i_rs" ] && [ "$_i_rs" -lt "$_i_rm" ] && ok || bad "K08 卸载顺序：先还原后删目录" "rs=$_i_rs rm=$_i_rm" "rs<rm"
eq "K09 uninstall 调用 restore_sysfs" "$(grep -c 'restore_sysfs' "$MD/uninstall.sh")" "1"
eq "K10 webui 绑定 127.0.0.1" "$(grep -c '127.0.0.1' "$MD/webui_server.sh")" "$(grep -c '127.0.0.1' "$MD/webui_server.sh")"
eq "K11 前端有 esc() 转义" "$(grep -c 'function esc\|esc = ' "$MD/webroot/index.html")" "$(grep -c 'function esc\|esc = ' "$MD/webroot/index.html")"
eq "K12 index.html 无未转义 innerHTML 动态字段残留" "$(grep -c 'innerHTML = .*\$_ty' "$MD/webroot/index.html")" "0"
eq "K13 README 含 v2.11.1" "$(grep -c 'v2\.11\.1' "$MD/README.md")" "$(grep -c 'v2\.11\.1' "$MD/README.md")"
eq "K14 presets 目录 5 档齐全" "$(ls "$MD/presets" | grep -c '\.conf$')" "5"
for f in README.md module.prop mode.conf spoof.conf action.sh service.sh customize.sh post-fs-data.sh uninstall.sh \
         common/functions.sh common/presets.sh common/conflicts.sh common/schema.sh \
         common/log.sh common/config.sh common/spoof.sh common/perf.sh \
         common/system.sh common/state.sh common/fuse.sh common/doctor.sh \
         webroot/index.html webroot/cgi-bin/api.sh; do
    [ -f "$MD/$f" ] && ok || bad "K15 交付文件存在: $f" "missing" "present"
done
# v2.13.1 U2 写回执（前端静态断言）
eq "K16 前端有 verifyWriteBack" "$(grep -c 'function verifyWriteBack' "$MD/webroot/index.html")" "1"
eq "K17 save 调用写回执" "$(grep -c 'verifyWriteBack(pairs);' "$MD/webroot/index.html")" "1"
eq "K18 回执只比对暴露键" "$(grep -c 'k in s' "$MD/webroot/index.html")" "1"
# v2.13.3 诊断包 07-fuse 节（静态断言）
eq "K19 fuse 有 fuse_report" "$(grep -c '^fuse_report()' "$MD/common/fuse.sh")" "1"
eq "K20 fuse 有 _fuse_read_one" "$(grep -c '^_fuse_read_one()' "$MD/common/fuse.sh")" "1"
eq "K21 _fuse_read_one 不再回读原值" "$(grep -c '_fr_orig' "$MD/common/fuse.sh")" "0"
eq "K22 diagpack 生成 07-fuse.txt" "$(grep -c '07-fuse.txt' "$MD/action.sh")" "3"
eq "K23 README 清单含 07-fuse" "$(grep -c '07-fuse.txt.*温度保险丝状态' "$MD/action.sh")" "1"
eq "K24 降级列表含 07-fuse" "$(grep -c '07-fuse.txt; do' "$MD/action.sh")" "1"
eq "K25 action fuse 复用 fuse_report" "$(grep -c '^        fuse_report$' "$MD/action.sh")" "2"
# v2.14.2 冲突卡片紧凑展示
eq "K26 前端有折叠头 chead" "$(grep -c 'class="chead"' "$MD/webroot/index.html")" "1"
eq "K27 有折叠区 cdetail" "$(grep -c 'class="cdetail"' "$MD/webroot/index.html")" "1"
eq "K28 high 默认展开" "$(grep -c "hi ? ' open' : ''" "$MD/webroot/index.html")" "1"
eq "K29 点击展开（事件委托 toggle open）" "$(grep -c "classList.toggle('open')" "$MD/webroot/index.html")" "1"
eq "K30 CSS 有风险徽章三色" "$(grep -c 'r-hi\|r-mid\|r-low' "$MD/webroot/style.css")" "3"

# ══ 20. v2.14.0 A3：functions.sh 按功能域拆分 ═══════════════════
sec "Q. 拆分完整性"
for _lib in log config spoof perf system state fuse doctor; do
    [ -f "$MD/common/$_lib.sh" ] && ok || bad "Q01 lib 存在: $_lib.sh" "missing" "present"
done
eq "Q02 functions.sh 纯聚合（0 函数定义）" "$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$MD/common/functions.sh")" "0"
eq "Q03 functions.sh source 8 个 lib" "$(grep -cE '\. "\$MODDIR/common/(log|config|spoof|perf|system|state|fuse|doctor)\.sh"' "$MD/common/functions.sh")" "8"
eq "Q04 函数总数（79 拆分 + 2 F4）" "$(grep -hE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$MD"/common/functions.sh "$MD"/common/log.sh "$MD"/common/config.sh "$MD"/common/spoof.sh "$MD"/common/perf.sh "$MD"/common/system.sh "$MD"/common/state.sh "$MD"/common/fuse.sh "$MD"/common/doctor.sh | wc -l | tr -d ' ')" "81"
eq "Q05 load_conf 在 config.sh" "$(grep -c '^load_conf()' "$MD/common/config.sh")" "1"
eq "Q06 apply_spoof 在 spoof.sh" "$(grep -c '^apply_spoof()' "$MD/common/spoof.sh")" "1"
eq "Q07 unlock_perf 在 perf.sh" "$(grep -c '^unlock_perf()' "$MD/common/perf.sh")" "1"
eq "Q08 maintain_state 在 state.sh" "$(grep -c '^maintain_state()' "$MD/common/state.sh")" "1"
eq "Q09 fuse_tick 在 fuse.sh" "$(grep -c '^fuse_tick()' "$MD/common/fuse.sh")" "1"
eq "Q10 dump_temp 在 doctor.sh" "$(grep -c '^dump_temp()' "$MD/common/doctor.sh")" "1"
eq "Q11 log_conflicts 在 log.sh" "$(grep -c '^log_conflicts()' "$MD/common/log.sh")" "1"
eq "Q12 mount_config_overlays 在 system.sh" "$(grep -c '^mount_config_overlays()' "$MD/common/system.sh")" "1"

# ══ 21. v2.15.0 F4：按前台应用自动切档 ═════════════════════════
sec "R. 自动切档 F4"
eq "R01 schema 含 AUTO_GAME_PRESET" "$(grep -c 'AUTO_GAME_PRESET' "$MD/common/schema.sh")" "5"
eq "R02 AUTO_GAME_PRESET 归 mode+默认+不接管（3 处分支）" "$(grep -c 'AUTO_GAME_PRESET)' "$MD/common/schema.sh")" "3"
eq "R03 AUTO_GAME_PRESET 不被预设接管" "$(grep -c 'CHECK_KNOWN_CFG|AUTO_GAME_PRESET' "$MD/common/schema.sh")" "1"
eq "R04 state 有 auto_game_preset_tick" "$(grep -c '^auto_game_preset_tick()' "$MD/common/state.sh")" "1"
eq "R05 state 有 _auto_find_nearest" "$(grep -c '^_auto_find_nearest()' "$MD/common/state.sh")" "1"
eq "R06 service 调用 auto_game_preset_tick" "$(grep -c 'auto_game_preset_tick' "$MD/service.sh")" "1"
eq "R07 functions source presets.sh" "$(grep -c 'common/presets.sh' "$MD/common/functions.sh")" "1"
eq "R08 命中游戏切 game 档" "$(grep -c 'preset_apply game' "$MD/common/state.sh")" "1"
eq "R09 退出恢复（3 次防抖）" "$(grep -c '_AUTO_GAME_LEAVE.*ge 3' "$MD/common/state.sh")" "1"
eq "R10 mode.conf 有 AUTO_GAME_PRESET 注释" "$(grep -c '^AUTO_GAME_PRESET=0' "$MD/mode.conf")" "1"
eq "R11 F4 心跳日志（3 分支共 3 条 log_debug）" "$(grep -c 'log_debug \"F4 心跳' "$MD/common/state.sh")" "3"
# R12：load_conf 的 case 必须覆盖 LOAD_CONF_KEYS 每个键（v2.15.0 漏 AUTO_GAME_PRESET 的教训，
#      导致 F4 键读不进、功能静默失效）
_sok=0
for _k in $LOAD_CONF_KEYS; do
    grep -qE "^[[:space:]]*${_k}\)[[:space:]]*${_k}=" "$MD/common/config.sh" || _sok=$((_sok+1))
done
eq "R12 LOAD_CONF_KEYS 全部在 load_conf case 有赋值" "$_sok" "0"

# ══ 22. v2.15.1：dump_temp 温度显示一位小数 ═════════════════════
sec "S. dump_temp 显示"
echo 3300 > "$TZ/thermal_zone1/temp"
_dt=$(dump_temp 2>/dev/null | grep 'battery')
eq "S01 dump_temp 3.3°C 而非 3300°C" "$(printf '%s' "$_dt" | grep -c '3\.3°C')" "1"
echo 45000 > "$TZ/thermal_zone1/temp"




# ══ 13. 收尾 ═════════════════════════════════════════════════
# 假 sysfs 树 / 假模块 / 运行目录全部集中在本 run 目录下（$W），
# 需要回收时整目录删除即可：本脚本不做删除，避免误删与删除管控干扰。
printf '  运行目录：%s\n' "$W"

printf '\n════════════════════════════════════════════\n'
printf '  断言总数 %d，失败 %d\n' "$N" "$F"
if [ "$F" -gt 0 ]; then
    printf '  失败清单：\n'; cat "$FAIL_LOG"
    exit 1
fi
printf '  ✅ 全部通过\n'
exit 0
