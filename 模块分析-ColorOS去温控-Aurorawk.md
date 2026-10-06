# 系统分析：ColorOS去温控（`id=Aurorawk`，冬雪v2）

- 对象：`C:\Users\10626\Desktop\00_待整理归档\ColorOS去温控.zip`（213 678 B / 15 个条目）
- 解压副本：`_analysis/coloros/`
- 分析手段：脚本逐行通读 + ELF 节/动态符号/`rodata` 静态抽取（未执行任何二进制）
- 日期：2026-10-04

---

## 0. 结论速览

| 级别 | 数量 | 代表问题 |
|---|---|---|
| **P0** | 5 | `chmod -R 777 $MODDIR`；`handle_partition` 目录嵌套致 `/vendor` 侧补丁失效；`wenkong` 前台阻塞且无守护；`libhook.so` 以子串 `temp` 判定 + LD_PRELOAD 可能整体失效；无 `uninstall.sh` 致 `/data/system` 原地改写不可回滚 |
| **P1** | 10 | `sed 's/fps=".*"/fps="144"/'` 吞掉行尾属性；`dirs` 重复路径；9 次全量 `find`；日志无轮转；强杀 `fuelgauged`；欺骗只写一次无重放；XML 头硬编码；action 按钮静默开关 USB 调试… |
| **P2** | 9 | 版本号/描述为纯装饰字符；`read` 无 `-r`；`ls` 解析；伪属性；仅 arm64 无校验；二进制无源码… |

**总体判断**：这是一个**功能覆盖面很宽、但工程成熟度低**的激进型模块。它的「配置批量改写」思路（9 类厂商 XML）与本项目同源，值得借鉴其**覆盖面**；但它的运行时（原生 hook + 强杀服务 + 777 权限）引入了本模块刻意规避的全部风险，不建议合并，也不建议在本项目目标机（GT8 / SM8750 / Android 16）上直接使用。

> 包体积构成：`bin/wenkong` 244 328 B + `bin/libhook.so` 390 200 B = 634 528 B，**占未压缩总量的 97%**。这两个文件是 arm64 (`EM_AARCH64`) 的 ELF，无源码、无构建信息、无校验值。

---

## 1. 业务目标与总体架构

### 1.1 目标

尽可能彻底地移除 ColorOS/realme UI 上的温控限制，手段覆盖四个层次：

| 层次 | 手段 | 实现位置 |
|---|---|---|
| ① 内核节点 | 向 `thermal_zone*/emul_temp` 写 29.5°C，`/proc/shell-temp` 写 0–9 | `service.sh` |
| ② 厂商配置 | 批量改写 9 类 XML/TXT/JSON 温控阈值 | `customize.sh` |
| ③ 系统属性 | `system.prop` 注入"关闭温控"类属性 | `system.prop` + `customize.sh:4-6` |
| ④ **进程级拦截** | `LD_PRELOAD` 注入 `libhook.so`，Hook `open/read/pread/fopen`，**在读文件这一步直接替换温度数据** | `bin/wenkong` + `bin/libhook.so` |
| ⑤ 服务停用 | `stop oppo_theias / thermal_mnt_hal_service / orms-hal-1-0 / fuelgauged / smartcharging`；`killall` / `pkill -9 -f` horae | `post-fs-data.sh`、`bin/wenkong` |

第 ④ 层是它区别于常见温控模块的地方：**不再依赖内核是否支持 `emul_temp`，而是在用户态把温度读数改掉**。

### 1.2 调用链

```
[安装]  update-binary → util_functions.sh → install_module
          └─ customize.sh
               ├─ setprop ×3
               ├─ find $dirs ×9 → 生成 $MODPATH/{system,vendor,my_product,…}/…（改写后的配置）
               ├─ patch_rr_config /data/system/refresh_rate_config.xml（原地 sed -i）
               ├─ handle_partition vendor|system_ext|product
               └─ set_perm_recursive $MODPATH 0 0 0755 0644   ← 二进制被置为 0644

[开机 post-fs-data]  post-fs-data.sh
               ├─ KSU 判定 → TARGET_FOLDERS（KSU 排除 odm）
               ├─ mount_system_files ×4  → mount --bind（my_* 走 /mnt/vendor/…）
               └─ stop ×5 个服务

[late_start service] service.sh
               ├─ chmod -R 777 "$MODDIR"          ← 补回执行位；副作用见 §4.1
               ├─ emul_temp 写入（按 type 白名单）
               ├─ /proc/shell-temp 写 0–9
               └─ $MODDIR/bin/wenkong（前台，无 &）

[原生守护]  wenkong
               ├─ ps -A | grep -c ' / killall / pkill -9 -f '（清场）
               ├─ setenv("LD_PRELOAD", "/data/adb/modules/Aurorawk/bin/libhook.so")
               ├─ setenv("TEMPCONTROL", …)
               └─ execl("/system/bin/linker64", …)   ← 带 hook 重启目标进程（含 /system_ext/bin/horae）

[被注入进程]  libhook.so
               ├─ hook open/fopen → 记录 fd
               ├─ read/pread → readlink("/proc/self/fd/%d") → 判定路径
               │    FileDetector::is_temperature_related(int)
               │      命中子串之一：thermal_zone / shell-temp / temp
               ├─ TemperatureController::current_temperature → 伪造内容
               └─ ThermalLogger::record() → /data/adb/modules/Aurorawk/log.md

[Action 按钮]  action.sh → 切换 settings global adb_enabled（与温控无关）
```

---

## 2. 模块划分

| 文件 | 职责 | 触发时机 | 可观��性 |
|---|---|---|---|
| `customize.sh` (10 288 B) | 9 类配置批量改写 | 安装期一次 | 仅安装日志，无成功/失败统计 |
| `post-fs-data.sh` | bind mount + 停 5 个服务 | 每次开机 | 全部 `2>/dev/null`，失败不可见 |
| `service.sh` | 温度注入 + 启动 wenkong | 每次开机 | 无日志 |
| `action.sh` | 切换 USB 调试 | 用户点击 | 通知 |
| `system.prop` | 5 组属性 | 每次开机 | — |
| `bin/wenkong` | 守护/重启/注入（arm64 PIE） | service.sh 拉起 | 无 |
| `bin/libhook.so` | 文件读取拦截（arm64 so） | 被 LD_PRELOAD | 写 `log.md` |

---

## 3. 技术要点与外部依赖

### 3.1 外部依赖（硬约束）

| 依赖 | 出现在 | 失效后果 |
|---|---|---|
| `arm64` 架构 | `execl("/system/bin/linker64", …)`；两枚 ELF 均为 `EM_AARCH64` | 非 arm64 设备完全无效，且**无架构校验**，安装不报错 |
| 模块目录必须是 `/data/adb/modules/Aurorawk` | `libhook.so` / `wenkong` 内硬编码该路径 | 改 `module.prop` 的 id 或目录名 → 原生层**静默失效** |
| Magisk `util_functions.sh` | `update-binary` 第 4 行 | 纯 KernelSU 且未装 Magisk 时安装路径不明（与 `post-fs-data.sh` 的 KSU 分支自相矛盾） |
| `/vendor/etc/thermal`（MTK） | `customize.sh:275` | 骁龙机不存在 → 整段跳过（正确） |
| `sysfs` 支持 `emul_temp` | `service.sh` | 不支持时报错被丢弃 |
| `LD_PRELOAD` 生效 | 原生层 | 见 §4.4 |

### 3.2 原生层逆向所得（静态，未运行）

`libhook.so` **导出**的符号直接暴露了设计：

```
_ZN12FileDetector22is_temperature_relatedEi        → is_temperature_related(int fd)
_ZN21TemperatureController19current_temperatureE   → current_temperature
_ZN13ThermalLogger6recordEPKcS1_                   → record(const char*, const char*)
_ZN13ThermalLogger14initialize_logEv / 8log_lock / 10log_handle
```

导入/拦截：`open`、`fopen`、`read`、`pread`、`write`、`dlsym`、`readlink`、`strstr`。

`.rodata` 中的自有字符串：

```
thermal_zone      shell-temp      temp
/proc/self/fd/%d
INTERCEPT   TEMPCONTROL
[%s] %s: %s (PID:%d).      %m-%d %H:%M:%S
/data/adb/modules/Aurorawk/log.md
ro.arch     exynos9810     yptnk        ← 与 wenkong 共有，语义不明
```

`wenkong` 的自有字符串：

```
/system/bin/linker64   LD_PRELOAD   /data/adb/modules/Aurorawk/bin/libhook.so
/system_ext/bin/horae  horae
stop    killall    pkill -9 -f '    ps -A | grep -c '
TEMPCONTROL  MANAGER  generic
/data/adb/modules/Aurorawk/log.md     14206865     yptnk
```

结论：`wenkong` = 「杀掉温控进程 → 用 `LD_PRELOAD` 把 `libhook.so` 塞回去重启」的守护程序；`libhook.so` = 按 fd 反查路径、命中关键字就在 `read()` 返回值上做替换的拦截器，日志落到 `log.md`。

---

## 4. 缺陷清单（按严重度）

### P0-1 `chmod -R 777 "$MODDIR"` —— 每开机把整个模块目录改成全局可写

```sh
# service.sh:2
chmod -R 777 "$MODDIR"
```

**成因链**：`customize.sh:321` `set_perm_recursive $MODPATH 0 0 0755 0644` 把 `bin/wenkong` 压成 **0644**（无执行位）→ `service.sh` 用 `chmod -R 777` 兜底补位。

**影响**
- 模块内所有文件（含以 root 运行的 `wenkong`）变为 `rwxrwxrwx`。任何能到达该路径的上下文都可替换二进制 → **下次开机以 root 执行任意代码**。当前缓解因素只是 `/data/adb` 本身为 `0700`，属于"靠上游权限兜底"，不是设计。
- `-R 777` 每次开机递归整个模块目录，属无谓 I/O。
- 日志文件也 777。

**改法**：`customize.sh` 末尾改为显式授权，删掉 `service.sh` 的 `chmod -R`：

```sh
set_perm_recursive $MODPATH 0 0 0755 0644
chmod 0755 "$MODPATH/bin/wenkong"
chmod 0644 "$MODPATH/bin/libhook.so"
```

---

### P0-2 `handle_partition 'vendor'` 目录嵌套 —— `/vendor` 侧补丁全部落空

```sh
# customize.sh:303-312
if [ -L "/system/$1" ] && [ "$(readlink -f /system/$1)" = "/$1" ]; then
    if [ -e $module/system/$1 ]; then
      mv -f $module/system/$1 $module/$1     # ← 关键
    fi
```

**触发条件**：只要 `find $dirs …` 在 `/vendor` 下命中过任一文件，`$MODPATH/vendor` 就已被 `mkdir -p $(dirname $module$file)` 创建。

**实测**（GNU mv / 目标目录已存在）：

```
mv -f src/vendor  dst/vendor   →  dst/vendor/vendor/etc/x   （嵌套，不是覆盖）
```

→ 最终路径变成 `$MODPATH/vendor/vendor/etc/...`，overlay 目标是 `/vendor/vendor/etc/...`，**该系统上不存在，补丁静默失效**；而且 `$MODPATH/system/vendor` 还留在原地，形成双份。

**改法**：改成"先合并再删源"，或干脆在 `dirs` 里去掉重复项（见 P1-2），从源头不再产生 `$MODPATH/system/vendor`：

```sh
if [ -e "$module/system/$1" ]; then
    cp -af "$module/system/$1/." "$module/$1/" 2>/dev/null
    rm -rf "$module/system/$1"
fi
```

---

### P0-3 `wenkong` 前台阻塞 + 无守护、无重启

```sh
# service.sh 最后一行
$MODDIR/bin/wenkong >/dev/null 2>&1
```

- 无 `&`：若 `wenkong` 是常驻循环，`service.sh` **永不返回**，拖住 late_start 阶段、影响后续模块与开机完成广播。
- 一旦 `wenkong` 被杀或崩溃，**没有任何重启机制**（它自己就是"监控程序"，却没人监控它）。
- stdout/stderr 全丢，故障时零线索。

**改法**：`nohup "$MODDIR/bin/wenkong" >>"$LOG" 2>&1 &`，并在模块主循环里做存活检查；或改为由 `post-fs-data.sh` 拉起并 detach。

---

### P0-4 `libhook.so` 的判定与注入机制两处硬伤

**（a）判定过宽** —— `.rodata` 里同时存在 `thermal_zone`、`shell-temp`、`temp` 三个关键字，`temp` 是子串匹配：

`/proc/self/fd/%d` 反查出的路径只要含 `temp` 就会被替换内容。命中面包括 `template/`、`attempt`、`/data/.../temp/` 等一大类无关路径；被注入进程若用同一套 `open/read` 读自己的配置（如 `/vendor/etc/thermal/*.conf`），会读到伪造内容 → **配置解析失败**，故障表现随机。

**（b）`LD_PRELOAD` 在 Android 上并不总是生效**

`wenkong` 用 `execl("/system/bin/linker64", …)` 重启目标进程来绕过 init。由此带来：
- 进程脱离 init 监管 → 崩溃后不再自动重启；
- SELinux 域继承自 `wenkong`（`u:r:su:s0` 一类）而非该服务本身的域 → 访问自身节点时**大概率被 SELinux 拒绝**；
- 若目标二进制是 32 位，或带 `AT_SECURE`（setuid/capability），linker 会**忽略** `LD_PRELOAD` → 整层静默失效；
- `LD_PRELOAD` 通过环境继承 → 目标进程 fork 出的**所有子进程都被注入**，爆炸半径不可控。

**改法**：判定改成精确路径前缀白名单（`^/sys/class/thermal/.*/temp$`、`^/proc/shell-temp$`），并记录未命中日志；注入改为 `init` 层可用手段（如 `setprop` + 服务自身支持），或至少在注入后校验 hook 是否真的生效（读一次已知温感比对），失效则回退到 `emul_temp` 方案并写日志。

---

### P0-5 无 `uninstall.sh` —— `/data/system` 的原地改写无法回滚

```sh
# customize.sh:100-104
rr_config=/data/system/refresh_rate_config.xml
if [[ -f $rr_config ]]; then
  cp -f $rr_config $rr_config.bak
  patch_rr_config $rr_config      # sed -i 原地改，共 4 条
fi
```

- 卸载模块不会恢复该文件；用户只能手动 `cp .bak` 回去。
- **二次安装时 `.bak` 会被已改过的版本覆盖** → 备份失去意义。
- `sed -i` 无原子写，安装中断即留半截文件。

**改法**：备份改为幂等（仅当 `.bak` 不存在时才 cp），并补 `uninstall.sh` 负责恢复 + 重启被 stop 的服务。

---

### P1-1 `sed` 贪婪匹配吞掉行尾属性

```sh
# customize.sh:111
sed -i "s/fps=\".*\"/fps=\"144\"/" $module$file
```

实测：

| 输入 | 输出 |
|---|---|
| `<level temp="480" fps="60" cpu="0x10"/>` | `<level temp="480" fps="144"/>` ← **`cpu` 被吞** |
| `<level fps="60"/>` | `<level fps="144"/>` |

`thermallevel_to_fps.xml` 中只要 `fps` 不是行内最后一个属性，数据即被破坏。
**改法**：`sed -i 's/fps="[^"]*"/fps="144"/'`（同本项目 v2.8.4 修复 `xml_override` 时的做法）。

---

### P1-2 `dirs` 含重复路径，配置被处理两遍

```sh
# customize.sh:9
dirs="/odm /my_product /my_stock /vendor /system/vendor /product /system"
```

现代 Android 上 `/system/vendor` 是 `/vendor` 的符号链接 → 同一文件被 find 命中两次，写出 `$MODPATH/vendor/...` 与 `$MODPATH/system/vendor/...` 两份，再叠加 P0-2 的 `mv` 嵌套。
**改法**：`dirs="/odm /my_product /my_stock /vendor /product /system"`（去掉 `/system/vendor`），或直接 `--bind` 去重。

---

### P1-3 安装期 9 次全量 `find`

`customize.sh` 中 `find $dirs -name ...` 出现在第 **31 / 95 / 107 / 116 / 148 / 166 / 212 / 223 / 249** 行，共 9 次；每次都要遍历 `/system`（十余万文件）× 6 个分区根，且 `/vendor` 与 `/system/vendor` 还要各走一遍 → 安装耗时可达数十秒到数分钟。
**改法**：改成一次 `find $dirs -type f \( -name a -o -name b … -o -name i \)`，按文件名分派处理函数。

---

### P1-4 日志无轮转，且每次拦截都落盘

`ThermalLogger::record()` → `/data/adb/modules/Aurorawk/log.md`，由 `log_lock` 串行保护。温控服务每秒读温感，被 hook 后**每次 read 写一条** `[%s] %s: %s (PID:%d).` → 持续增长 + 每次都带一次 `open/write/close` 与锁竞争。
**改法**：加大小上限（超过 N MB 截断）或默认关闭，仅在调试时开。

---

### P1-5 `post-fs-data.sh` 强杀 `fuelgauged` / `smartcharging`

```sh
stop oppo_theias
stop thermal_mnt_hal_service
stop orms-hal-1-0
stop fuelgauged
stop smartcharging
```

前三个是温控/性能链路，尚属题内；`fuelgauged`（电量计 HAL）与 `smartcharging`（智能充电）直接影响**电量上报与充电策略**，且 Android 16 上停 HAL 服务的后果不可预期。本项目 `mode.conf` 把 `STOP_SERVICES` 默认设为 0 正是出于同一顾虑。
**改法**：把这两条挪到可选开关，默认关闭。

---

### P1-6 温度欺骗只写一次，无重放、无存在性判断

```sh
for tz in /sys/class/thermal/*; do
  if [[ -f $tz/temp ]]; then
    case $(cat $tz/type) in … ) echo $t > $tz/emul_temp ;; esac
  fi
done
```

- 只在 late_start 执行**一次**；若厂商守护重写、或其它模块介入、或热插拔新增 zone，再无纠正。
- 未判断 `$tz/emul_temp` 是否存在 → 不支持的内核上每条都报错（被丢弃）。
- 本项目 v2.8.2 起已改为 `spoof.list` 记账 + 主循环周期重放（≤30 s），可直接借鉴。

---

### P1-7 过滤规则过猛，产物可能是残缺/非法 XML

```sh
# customize.sh:34
rows=$(cat $file | grep -v -E '(<gear_config|cpu=|fps=|<scene_|</scene_|<category_|</category_|<subitem|<level|\.)')
```

分支里的 `\.` 会**删掉所有含英文句点的行**（版本号、路径、带点的属性几乎全中），随后再 `sed` 替换 bool/int 项。产出物是否仍是合法 XML 完全取决于原文件写法，没有校验。
**改法**：对结构化 XML 用精确标签定位改写（本项目 `xml_override` 即 `<K>[^<]*</>`），不要整行删除；改写后至少做一次 `grep -c '</'` 之类的闭合检查并写日志。

---

### P1-8 XML 头尾硬编码，大小写/属性一变即产出非法文件

```sh
# customize.sh:135
'<?xml version="1.0" encoding="UTF-8"?>'|'<filter-conf>'|'</filter-conf>')
```

源文件若是 `encoding="utf-8"`（小写）或根节点不同，头/尾行被 `case` 落到默认分支丢弃 → 缺少声明或根节点不闭合。
**改法**：只过滤 `<name>` 白名单，头尾原样透传。

---

### P1-9 `action.sh` 静默开关 USB 调试（安全 + 预期违背）

```sh
on_off=$(settings get global adb_enabled 2>/dev/null)
if [ "$on_off" = "1" ]; then settings put global adb_enabled 0 …
elif [ "$on_off" = "0" ]; then settings put global adb_enabled 1 …
```

- 用户在管理器点「动作」按钮，预期是温控相关操作，实际是**翻转 ADB 开关**；若原为关闭，一次点击即**静默打开 USB 调试**。
- `settings get` 返回 `null` 时两个分支都不进 → `$title`/`$text` 为空，仍发一条空通知。
**改法**：动作按钮改为「重新应用温控 / 输出诊断」；或至少在通知里明确写明当前状态并加二次确认。

---

### P1-10 模块 id 硬编码进原生层

`wenkong` / `libhook.so` 内均为 `/data/adb/modules/Aurorawk/...`。改 `module.prop` 的 `id` 或目录名 → 日志路径不可写、`libhook.so` 找不到 → `execl` 失败、hook 静默失效。
**改法**：路径改为运行时传参（`TEMPCONTROL` 之外再加 `MODULE_DIR`），或由 `service.sh` 先 `export` 再拉起。

---

### P2 级（摘要）

| # | 位置 | 问题 |
|---|---|---|
| 1 | `module.prop` | `version=꒰ঌ冬雪v2໒꒱`、`description=❄️ฅ小᳐苓大王᳐੭❄️` —— 无法做版本比较，且**完全看不出模块做什么** |
| 2 | `customize.sh:121/153/227/253` | `while read line` 缺 `-r`，反斜杠被解释 |
| 3 | 同上 | 逐行 `echo … >> $module$file` → 每行一次 open/close；应改为 `{ … } > file` 一次性重定向 |
| 4 | `customize.sh:259-261` | `charging_*txt` 每行 3 次 `awk` fork |
| 5 | `customize.sh:278` | `for file in \`ls $mtk_t\`` 解析 `ls`，空格/特殊字符即崩 |
| 6 | `customize.sh:289-292` | MTK 分支把 `/vendor/etc/thermal` 下**所有** conf 替换成 `disable_skin_control.conf` 的内容 |
| 7 | `system.prop` | `sys.thermal.enable` / `oplus.dex.tempcontrol` 疑似自造属性；`sys.*` 重启即失；`ro.*` 在 post-fs-data 阶段写入，多数消费者已早于此时读取 |
| 8 | `post-fs-data.sh:7` | `command -v ksud` 判定 KSU，但 `update-binary` 仍依赖 `/data/adb/magisk/util_functions.sh` —— 两条路径自相矛盾 |
| 9 | `post-fs-data.sh:8` | `mount --bind` 到 `/mnt/vendor/my_product/...`：仅在 `/my_product` 是指向 `/mnt/vendor/my_product` 的符号链接时才成立；真分区挂载的机型上**全部 `my_*` overlay 静默失败**（`2>/dev/null` 吞掉错误） |
| 10 | 各脚本 | 大量 `[[ ]]` / `local`，非 POSIX；包内无 `uninstall.sh`、无 `README`、无 `sepolicy.rule` |

---

## 5. 改进建议（按落地优先级）

| 优先级 | 动作 | 位置 | 成本 |
|---|---|---|---|
| 1 | 删 `chmod -R 777`，改为安装期 `chmod 0755 $MODPATH/bin/wenkong` | `service.sh:2` / `customize.sh:321` | 2 行 |
| 2 | `wenkong` 改后台 + 存活守护 + 日志落盘 | `service.sh` 末行 | 3 行 |
| 3 | 补 `uninstall.sh`：恢复 `/data/system/*.bak`、重启被 stop 的服务、卸载 bind | 新增 | ~20 行 |
| 4 | `dirs` 去 `/system/vendor`；`handle_partition` 改 `cp -af` 合并 | `customize.sh:9 / 303-312` | 5 行 |
| 5 | 所有 `sed "s/x=\".*\"/…"` 改 `[^"]*` | `customize.sh:22 / 37 / 41 / 111` | 4 处 |
| 6 | 9 次 `find` 合并为 1 次 | `customize.sh` 全文 | 中 |
| 7 | `my_*` 挂载目标同时尝试 `/my_product/...` 与 `/mnt/vendor/my_product/...`，并回显失败 | `post-fs-data.sh` | 小 |
| 8 | `fuelgauged` / `smartcharging` 改为可选开关，默认关 | `post-fs-data.sh` | 2 行 |
| 9 | 日志加上限/默认关 | 原生层（需源码） | 需源码 |
| 10 | `action.sh` 改为诊断/重放，不再动 ADB | `action.sh` | 重写 |
| 11 | `module.prop` 的 version/description 改为可读、可比较 | `module.prop` | 2 行 |
| 12 | 原生层路径不再硬编码；加架构校验 | 原生层 + `customize.sh` | 需源码 |

**若要继续用这套方案，最现实的前置条件是拿到 `wenkong` / `libhook.so` 的源码** —— 否则第 9、12 项以及 P0-4 的判定精度都无法真正修复，634 KB 二进制会长期成为不可审计的黑盒。

---

## 6. 与本项目（真我GT8优化模块 v2.8.6）的对照

| 维度 | 本包 | 本项目 v2.8.6 |
|---|---|---|
| 欺骗生效判定 | 无记账，写完即忘 | `spoof.list` 记账 + 周期重放（≤30 s） |
| 写入前校验 | 不判断节点是否存在 | `spoof_supported` 探测 |
| 亮度保护 | 无；且改 `oppo_display_perf_list.xml`、`/proc/shell-temp`、`vendor.display.hightempaging_dbv` | `DISPLAY_PROTECT=1`、`UNLOCK_CDEV=0`、`bsafe` 预设、`diag` 嫌疑排查 |
| 停服务 | 无条件停 5 个（含 `fuelgauged`） | `STOP_SERVICES=0` 默认关，逐项按需 |
| 权限 | `chmod -R 777` 每开机 | 安装期 `set_perm`，运行期不 chmod |
| 可观测性 | 全部 `2>/dev/null`，无日志无 WebUI | 日志 + WebUI + `action.sh status/diag/conflicts` |
| 冲突检测 | 无 | Tier A/B + v2.8.6 新增 Tier C 资源扫描 |
| 可审计性 | 97% 体积是不可读二进制 | 全 shell，可逐行审阅 |

**值得借鉴的 2 点（已在 v2.8.7 落地）**：
1. **配置改写覆盖面** —— 它的 9 类目标（`sys_thermal_control_config*.xml`、`sys_high_temp_protect*xml`、`game_thermal_config.xml`、`QEGA_Config.txt`、`devices_config.json`、`charging_*txt`、`thermallevel_to_fps.xml`、`oppo_display_perf_list.xml`、`sys_resolution_switch_config.xml`）可以作为一份"厂商温控配置文件清单"核对本项目 `PATCH_THERMAL` / `PATCH_EXTRA` 是否漏项。
   > **核对结果**：9 类里我们有 7 类，**漏了 `refresh_rate_config.xml` 与 `sys_resolution_switch_config.xml`**。
   > 落地方式：登记进 `customize.sh` 的 `KNOWN_CFG`（12 项），安装期扫分区 + `/data/system`，
   > 结果写 `patched/known.list` 区分 `patched` / `seen` —— **只登记，不改写**。
   > 不改写的原因：`rateId` 语义在 Aurorawk（改 `2-2-2-2`→`0-0-0-0`）与慕容（全部改 `3-3-3-3` 锁 120Hz）
   > 之间互相矛盾，盲改等于掷骰子；`sys_resolution_switch_config.xml` 结构未验证，且我们刚在
   > v2.8.4 修过「改写产出损坏 XML」的 P0。更根本的是：本模块靠 `emul_temp` 造假温度，
   > 降帧/降分辨率本就不会触发，改这两个文件是冗余手段、风险却高得多。
2. **`refresh_rate_config.xml` 也存在于 `/data/system/`** 这一处运行时副本（本项目目前只扫分区，未考虑 `/data/system` 下的运行时拷贝）。
   > 落地方式：新增 `RUNTIME_SNAPSHOT=1`，安装期把 `/data/system/` 下显示类副本
   > **首次快照**到 `/data/adb/thermal_remove/runtime_backup/`（只在快照不存在时写，
   > 二次安装不会把改坏的版本设成新基准）。配套 `action.sh rr_restore` 一键还原、
   > `action.sh diag` 显示「与首次快照是否一致」。
   > 快照**放在模块目录之外**：`uninstall.sh` 原本 `rm -rf /data/adb/thermal_remove`
   > 会连快照一起删，已改为先移出、删完再移回 —— 因为「别的模块改坏又无卸载脚本」
   > 这种事恰恰最可能发生在卸载本模块、换模块之后。

**不应借鉴的**：原生 hook 层、无条件停 HAL 服务、777 权限、一次性写入无重放。
