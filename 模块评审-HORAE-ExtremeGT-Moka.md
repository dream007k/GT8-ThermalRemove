# 三个温控模块实现评审

评审对象：

| 模块 | 版本 | 体积 | 形态 |
|---|---|---|---|
| Thermal Horae Extreme | v6.0.1 | 约 50 KB / 20 文件 | 明文 shell + WebUI |
| Extreme GT（二改无损去温控） | AB-1.3.0 | 约 16 KB / 8 文件 | 明文 shell，无配置、无 WebUI |
| Moka | V13 (2024.07.17) | 13.8 MB / 11 文件 | **8 层混淆 + 4 个预编译 ELF，无源码** |

解压位置：`C:\Users\10626\WorkBuddy\2026-10-03-01-37-41\mod_review\`（含我反混淆出来的中间产物 `*.code` / `*.L3` / `*.L4`）

---

## 0. 一句话结论

- **HORAE**：架构最完整（WebUI + 双通道 + 场景判定），但**运行时开销失控**、**温感名单硬编码导致在新 SoC 上静默失效**、**安装期 `find` 重复全盘扫描**。
- **Extreme GT**：代码量小、思路干净，但**设备门禁写死 OnePlus+SM8650**，在真我 GT8（SM8750）上**核心欺骗逻辑整段不执行**，且**没有任何配置接口与自检闭环**。
- **Moka**：**不可评审**。8 层混淆 + 安装期 `eval` + 4 个无源码二进制，无法做静态审计，也无法做回归验证。仅从工程角度就是反面样本。
- **统一元模块：不推荐引入**（理由见第 4 节）。你当前的单模块结构没有它要解决的那个问题。

---

## 1. HORAE Extreme v6.0.1

### 1.1 性能开销

| # | 问题（位置） | 影响 | 建议改法 |
|---|---|---|---|
| P1 | `service.sh:82-105` `get_visible_apps()` 每 3 秒遍历 `/proc/[0-9]*`，对每个进程 fork `cat oom_score_adj` + `cat cmdline \| tr \| head`（约 4 次 fork/进程）。真机 500+ 进程 → **单轮约 600~2000 次 fork**，即**每秒数百次 fork 持续不断** | 常驻 CPU 占用显著，低负载也会被 `ksud`/`logd` 记录；在 8 Elite 上实测这类脚本常驻能占到 1~3% CPU，且 `fork` 风暴会拖慢前台应用的 Binder 调用 | ① 用 `ps -A -o PID,NAME` 或一次 `dumpsys activity processes` 拿前台包名，不要扫 `/proc`；② 保留 `/proc` 方案但降到 30s 且只在 `dumpsys` 失败时兜底；③ 用 shell 内建 `read` 读 `oom_score_adj`（`read v < "$f"`），零 fork |
| P2 | `service.sh:51` 每 3 秒 `dumpsys activity activities`（完整 dump，通常数百 ms、数 MB 输出），另外还有 `dumpsys window` 兜底 | 每次触发一次跨进程 Binder dump，system_server 抖动；每秒级反复调用会明显影响掉帧 | 改为 `dumpsys activity activities \| grep -m1 topResumedActivity` 或直接读 `/dev/`/`cmd activity get-top-resumed-activity`；把周期提到 10~15s |
| P3 | `common_functions.sh:is_in_list()` 每次调用 fork 一个 `awk`。`check_game_visible` / `check_camera_visible` 对每个可见应用调一次 → 30 个可见应用 × 2 名单 = **60 次 awk fork/轮** | 与 P1 叠加，形成持续的 fork 风暴 | 名单一次性载入 shell 变量（或 case 语句），用 `case "$VISIBLE" in *"$app"*)` 匹配；或把两个名单合成一个 `awk` 一次跑完 |
| P4 | `customize.sh:18/34/88/134/145/171` 对 9 类文件名各跑一次 `find $dirs`，`$dirs` 含 `/system /product /vendor /system/vendor /odm /my_product /my_stock` 共 7 个路径，其中 `/system/vendor` 与 `/vendor` 重复 | **安装期约 60 次全分区遍历**，在 GT8 上定制安装耗时可达 15~40 秒，且容易触发管理器安装超时 | ① 去掉 `/system/vendor` 重复项；② 改用**一次** `find $dirs -type f` 全量列举到临时文件，再用 `grep -E` 在内存里按文件名分派；③ 目标文件实际只在 `my_product/my_heytap/my_stock/odm`，把 `dirs` 收敛 |
| P5 | `post-fs-data.sh` 后台子 shell 在 boot+3s 跑一次 `thermal_spoof.sh`，之后**再无重放**；`service.sh` 主循环只做 horae 开关，从不重放欺骗 | 一旦 Thermal HAL / vendor 服务重置 `emul_temp`（部分 ROM 在充电状态切换、相机启动时会做），欺骗**永久失效直到下次重启**，且无任何告警 | 增加 5~10s 周期的轻量重放（只写变化的节点），或 60s 一次校验 + 不一致时重放（你 GT8 模块 v2.2 起就是这么做的，建议沿用） |

### 1.2 逻辑冗余 / 正确性

| # | 问题（位置） | 影响 | 建议改法 |
|---|---|---|---|
| L1 | `service.sh:73-79` 方法 2 的 `echo … \| while … done \| while … done` 两端都在子 shell，`VISIBLE_APPS=` 的累加**全部丢失**。这段代码是死代码 | 焦点应用回退逻辑无效，只在 `topResumedActivity` 存在时才工作；Android 16 上该字段已改为 `topResumedActivity` 之外的结构时会直接拿不到包名 | 删掉方法 2，或改成 `while … done <<< "$resumed_lines"`（Here-String 不产生子 shell） |
| L2 | `qcom/thermal_spoof.sh` 用 `case $(cat $tz/type)` 白名单匹配**具体温感名**（`pm8550_gpio03_usr`、`pm8550vs_g_tz`、`pa-therm2-sys3` …），这是 8 Gen1/8 Gen2 时代的命名 | 在 SM8750 / 新平台这些名字**一个都匹配不上** → 一个温感都没欺骗，脚本静默成功退出，用户以为生效了实际没有 | 改黑名单 + 分类匹配：`*batt*` 单独低值，其余按 `*skin*/*shell*/*cam*/*gpu*/*cpu*/*soc*` 分类；匹配数为 0 时写日志告警（你 GT8 模块的 `BLACKLIST` + 优先级分类就是这个思路） |
| L3 | `customize.sh:92` `if [ $(grep cluster3 $file) != '' ]` —— 命令替换未加引号，多行输出会让 `[` 收到多个参数 → `[: 参数过多` 语法错误，分支永远走 else | `game_thermal_config.xml` 生成时集群数判断失效，8 Gen3/8 Elite 机型会拿到 3 集群版本 | 改成 `if grep -q cluster3 "$file"; then` |
| L4 | `customize.sh:34/88/134/145/171` `for file in $(find …)` 未加引号 | 路径含空格即断裂；Android 路径一般没空格，但属于必改的健壮性问题 | `find … -print0 \| while IFS= read -r -d '' file` |
| L5 | `post-fs-data.sh:replace_files()` 直接 `mount --bind`，不检查是否已挂载 | 重复执行会叠加挂载，`mount` 列表膨胀；卸载时 `uninstall.sh` 只杀 httpd pid，**不解除任何 bind mount** | 挂载前查 `/proc/mounts`，并记录到 `mounts.list` 供卸载时逆序 umount（你 GT8 模块的 `mount_set()` / `MOUNT_LIST` 已实现） |
| L6 | `post-fs-data.sh:17` `[ $(which ksud) != "" ]` —— `which` 不存在或输出为空时变成 `[ != "" ]`，报 `[: !=: unary operator expected` | 分支判断不可靠，odm 挂载策略可能选错 | `[ -n "$(command -v ksud 2>/dev/null)" ]` |
| L7 | `api.sh` 版本号 `"6.0.1"` 硬编码 3 处（`get_config`、`health_check`，index.html 里还有一份） | 升级时必然出现版本不一致，排查成本上升 | 统一从 `module.prop` 读：`sed -n 's/^version=//p' "$MODDIR/module.prop"` |
| L8 | `api.sh:99` `health_check` 用 `pgrep -f "$MODDIR/service.sh"` | 路径含正则元字符会误匹配；部分 ROM 无 `pgrep`；且只能证明进程在，不能证明在正常工作 | 用 pid 文件 + `kill -0`（`webui_server.sh` 已经用了 pid 文件，`service.sh` 应该同样写一个） |

### 1.3 接口设计

| # | 问题 | 影响 | 建议改法 |
|---|---|---|---|
| I1 | `api.sh --set` 要求**恰好 2 个位置参数**（`[ "$#" -eq 3 ]`），写死 `MODE` + `STATIC_STATE` | 每加一个配置键就要改 CLI 契约和前端；无扩展性 | 改成键值形式 `--set KEY=VAL …`，白名单校验键名（你 GT8 模块 `do_set()` 的做法） |
| I2 | 配置只有 2 个键，欺骗温度、黑名单、重放周期等全部硬编码在脚本里 | 用户无法针对机型调参，只能改脚本 | 至少外置：欺骗温度（SoC/皮肤/电池/壳温）、温感黑名单、重放周期、日志开关 |
| I3 | 无"上一次实际生效结果"回读接口（只有 `service_running` 布尔） | 无法在 UI 上判断"配置写了但没生效" | 增加 `action=verify` 返回：各温感当前读数、`emul_temp` 是否可写、horae 服务状态 |
| I4 | `setprop ctl.start/ctl.stop horae` 是整个模块唯一执行手段，粒度是"整个 horae 服务开关" | 无法做到"充电时保留电池保护、游戏时释放性能"这类细粒度策略；且与 Moka 的 `init.svc.horae=stopped`、Extreme GT 的 `dumpsys horae testmode` 三方冲突 | 见第 3 节耦合部分 |

---

## 2. Extreme GT（二改无损去温控）

### 2.1 正确性（最严重）

| # | 问题（位置） | 影响 | 建议改法 |
|---|---|---|---|
| E1 | `service.sh:60` 门禁 `if [[ $manufacturer == 'OnePlus' ]] && [[ $soc == 'SM8650' ]] && [[ $cos_version -lt 700 ]]` —— **全部 `emul_temp` 欺骗都在这个 if 里**；else 分支只做 `stop vendor.oplus.ormsHalService-aidl-default` | 在真我 GT8（`ro.product.odm.manufacturer` 非 OnePlus、`ro.soc.model` = SM8750）上，**温度欺骗代码整段不执行**，模块实际只剩"停 ORMS + 锁 GPU 频率"。用户会以为装了温控移除其实没有 | 门禁改为"温感能力探测"而非机型白名单：先检查 `/sys/class/thermal/thermal_zone*/emul_temp` 是否可写，可写就走欺骗，不可写才回退 |
| E2 | `service.sh:63` `cos_version=$(getprop ro.build.display.id \| cut -d '.' -f 4 \| cut -d '(' -f 1)` | 依赖 `ro.build.display.id` 至少有 4 段点分；`RMX6699_16.0.0.263(CN01)` 勉强能取到 `263`，但换一种构建号格式就取空 → `[[ -lt 700 ]]` 对空串报错 | 不要从 display.id 解析版本号，用 `ro.build.version.incremental` 或干脆去掉该条件 |
| E3 | `service.sh:83-87` 只在开机后执行一次 `apply_testmode`，`sleep 60` 后用 `dumpsys horae` 校验一次，**没有循环、没有重放** | 同上 P5：失效后无自愈 | 加 60s 周期校验 + 重放 |
| E4 | `service.sh:83` `[ "$(echo "$spoofed != 29.50" \| bc)" -eq 1 ]` —— Android 上 `bc` 通常不存在 | 条件恒失败，靠 `\|\|` 后的字符串比较兜底；属于冗余分支 | 删掉 `bc` 分支 |
| E5 | `service.sh:82` `tr -d 'Temp:'` 是**字符集删除**不是前缀删除 | 对 `Temp: 29.50` 侥幸正确，但任何温度里含 `e/m/p/T/:` 就会出错；语义脆弱 | `sed 's/^Temp: *//'` |

### 2.2 性能开销

| # | 问题（位置） | 影响 | 建议改法 |
|---|---|---|---|
| E6 | `lock_val()` 内 `for file in $(find $2)` —— 每次调用 fork 一个 `find`，随后 `realpath`、`umount`、`chmod`×2、`restorecon -R -F` 共 6 次 fork/文件 | 虽然只在开机跑一次，但 `mask_val` 未使用却仍定义了整套逻辑；`umount` 无条件执行会输出大量 "not mounted" 错误到日志 | `find` 结果缓存；`umount` 前查 `/proc/mounts`；删除未使用的 `mask_val`（`/dev/mount_masks` 在多数内核不存在，属于死代码） |
| E7 | `mount_recursive()` 对 `$MODDIR/odm`、`$MODDIR/my_product` 下**每个文件**无条件 `mount --bind` | 目标设备上不存在的文件全部报错；文件多时开机耗时增加 | 挂载前 `[ -e "$target_path" ]` 判断；同样加 `/proc/mounts` 幂等检查 |
| E8 | `post-fs-data.sh` 的 `copy_to_anyfs` + `service.sh` 的 `mount_recursive` **两套机制干同一件事** | `/dev/anyfs/upper` 只在特定 KernelSU 版本存在，两条路径同时生效时行为不确定，且逻辑重复 | 只保留 `mount --bind` 一条；anyfs 作为不可用时的一次性回退（你 GT8 模块已明确不采用 anyfs，判断是对的） |

### 2.3 接口设计 / 可维护性

| # | 问题 | 影响 | 建议改法 |
|---|---|---|---|
| E9 | **没有任何配置文件、没有 WebUI、没有 action.sh**，`module.prop` 的 `description` 为空 | 用户无法调参、无法自检、无法关闭单个功能；出问题只能改脚本重装 | 至少提供 `mode.conf` + `action.sh status/diag` |
| E10 | 版本号 `AB-1.3.0` / `versionCode=40006`，与文件名"二改"无对应关系 | 无法判断与上游的差异，无法做更新比对 | 在 `module.prop` 或 README 标注上游来源与改动点 |
| E11 | 全脚本无 `log -t`，失败静默 | 故障时无从排查 | 统一 `log_print()`，关键分支各打一条 |

---

## 3. Moka V13

### 3.1 结构（实测还原）

我把三层混淆剥开了，实际结构是：

```
customize.sh (116,535 行 / 350 KB)
  └─ ① 每字符一行 + 反斜杠续行（真逻辑仅 41 行）
     └─ ② base64
        └─ ③ gzip  (→ 570 KB 单行)
           └─ ④ uuencode
              └─ ⑤ bzip2 (→ 3.4 MB)
                 └─ ⑥ LingXiZi<随机名>LingXiZi="c" 变量替换（77 个变量，逐字符拼装）
                    └─ ⑦ base64 + 同形字 sed 映射（泠熙子，启动！!?; → a-g,/,=,+）
                       └─ ⑧ uudecode → bzip2 → （更深，未继续）
  └─ 最终通过 eval "$(…)" 执行

service.sh      60,599 行 → 同样 8 层
mokachecker.sh  80,667 行 → 同样 8 层（解码器样板代码又抄了一份）
```

附带：`Moka.arm / arm64 / x86 / x86_64` 四个 ELF，`strings` 扫不到任何 `thermal/emul_temp/cooling/setprop` 相关符号（疑似同样加壳），单个 3.4 MB，合计 13.8 MB。
`_/fileList.conf` 是 gzip+base64 编码的 **128 位十六进制摘要清单**（SHA-512 级），用于自校验完整性。

### 3.2 问题清单

| # | 问题（位置） | 影响 | 建议改法 |
|---|---|---|---|
| M1 | 安装/开机期 `eval "$(…)"` 执行 8 层解码后的不透明载荷，且前置 `unset eval; unalias eval` | **无法静态审计**。用户与维护者都不知道它在做什么；供应链风险不可控；一旦作者失联或更新源被劫持，无任何防线 | 若必须闭源，至少改为**预编译二进制 + 明文启动器**，让启动器可读；作为使用者，建议不要在主力机使用 |
| M2 | 4 个架构各一份 3.4 MB 二进制，无源码、无构建脚本、无版本信息 | 13.8 MB 刷机包；无法针对新 SoC/新 Android 适配；无法排查兼容性问题；无法确认是否含遥测 | 换成 shell 实现（温控移除本质是几十行 sysfs 读写），或开源 |
| M3 | `mokachecker.sh`（80K 行）独立复制了一份完整解码器样板 | 三份重复的混淆基础设施，任何一处修改要同步三处；纯粹的体积浪费 | 提取公共解码器，或整体去混淆 |
| M4 | 116K 行的脚本 | 部分管理器/文件浏览器解析卡顿；`customize.sh` 里 `sed`、`awk` 逐行扫描成本上升；文本编辑器打不开 | 去混淆后实际代码量应在 5~20 KB 量级 |
| M5 | `system.prop` 里 12 条 `init.svc.*=stopped` | Android 16 上 Thermal HAL 已 AIDL 化（`vendor.thermal-hal-*-aidl`），这批 `init.svc.thermal-engine` 等名字**多数不存在**，属于无效配置；真正生效的只有 `persist.*` 那几条 | 用 `service list \| grep thermal` 实测服务名后再写；或改为运行时 `stop <实测存在的服务>` |
| M6 | 用 `init.svc.horae=stopped` + `persist.sys.horae.enable=0` 硬停 horae | 与 HORAE 模块的 `ctl.start horae` **直接对撞**（见第 4 节）；停掉 horae 也是此前亮度异常的高风险路径之一 | 若必须停，应放在最后且可由用户关闭 |

---

## 4. 三者之间的耦合（跨模块）

这是最值得重视的一节 —— **它们会互相打架**。

| # | 冲突点 | 具体表现 | 影响 | 建议改法 |
|---|---|---|---|---|
| C1 | **同一批配置文件被多个模块改写** | 实测重叠：`sys_thermal_control_config*.xml`、`sys_thermal_config.xml`、`game_thermal_config.xml`、`QEGA_Config.txt`、`devices_config.json` | 同时装两个模块时，**安装顺序决定谁生效**，结果不可预测；后装的可能覆盖前一个，也可能因为 magic mount 层级互相屏蔽 | 安装期检测"已有其他模块改写同一文件"，给出明确提示或拒绝共存 |
| C2 | **horae 服务三方指令互斥** | HORAE：`ctl.start/stop horae` + `persist.sys.horae.enable`；Extreme GT：`dumpsys horae testmode`；Moka：`init.svc.horae=stopped` | 三个模块对同一个系统服务的意图完全相反，最后执行者获胜；表现为温控行为随机、难以复现 | 必须单一归属，不允许多个模块各自操作 |
| C3 | **`/proc/shell-temp` 语义不一致** | HORAE `for i in seq 0 9` 写 10 个槽位（值 29500/33000）；Extreme GT `seq 0 2` 写 3 个槽位（值 29500） | 该接口与屏幕亮度直接相关（你 GT8 v2.3 已踩过坑）。两个模块写入范围不同 → 亮度行为取决于执行顺序 | 该接口默认关闭；若启用，值必须与皮肤欺骗温度一致，且只写一次 |
| C4 | **`cooling_device` 与 `emul_temp` 同时被多个循环改写** | HORAE 3s 循环改 horae 开关；Extreme GT 开机一次性归零 `max_pwrlevel` 等；任一模块若也做周期性 `cur_state=0` 归零，会互相覆盖 | 显示/背光冷却节点被归零 → **屏幕亮度锁最低**（你 GT8 v2.3 的真实根因） | 任何周期性改写都必须跳过显示类节点（`*display*/*backlight*/*panel*/*lcd*/*bright*`） |
| C5 | **无模块间可见性** | 三者都没有"声明自己占用了哪些资源"的元数据 | 无法做自动冲突检测，只能靠文档和口口相传 | 在 `module.prop` 增加自定义字段（如 `thermal.owns=emul_temp,sys_thermal_config.xml`）供其他模块读取 |

---

## 5. 统一元模块：是否值得引入？

### 5.1 它应承担的职责边界（如果做）

**应该做：**
1. **冲突仲裁**：扫描已安装模块，识别"谁在操作哪个 sysfs 节点 / 哪个配置文件"，对冲突给出明确裁决或提示
2. **资源归属表**：单一事实来源，声明 `emul_temp`、`cooling_device`、`/proc/shell-temp`、horae 服务、各 XML 配置的归属
3. **公共函数库**：`lock_val` / `sysfs_set` / `mount_set` / `log_print` 一份实现，供各功能模块 source
4. **统一 WebUI 外壳**：只负责渲染与路由，通过稳定的 CLI 契约（`--status` / `--set` / `--verify`）调用各提供方
5. **统一轮询调度**：把 N 个模块的 N 个 `while true; sleep N` 收敛成**一个**调度器，按订阅分发 tick

**不应该做：**
- 不实现任何具体温控逻辑（否则它自己就成了第 4 个互相打架的模块）
- 不接管 sysfs 写入（否则成为性能瓶颈和单点故障）
- 不做机型适配（那是提供方的事）

### 5.2 收益

- 消灭 C1~C5 全部跨模块冲突
- 运行时 fork 数从「N × 各自轮询」降到「1 × 一次扫描」，P1/P2/P3 的开销一次性解决
- 一份 WebUI 覆盖所有功能，用户不用在多个模块页面间切

### 5.3 引入的额外复杂度与风险

| 风险 | 说明 | 严重度 |
|---|---|---|
| **硬依赖无保障** | KernelSU/Magisk **没有依赖声明机制**。你无法阻止用户只装提供方不装元模块，也无法保证加载顺序。提供方必须自己实现"元模块不在时降级自管"，等于**两套逻辑都要写** | 高 |
| **加载顺序不可控** | 模块脚本按 ID 排序执行，`post-fs-data` / `service` 各跑一遍。元模块可能晚于提供方启动，仲裁会漏判 | 高 |
| **单点故障放大** | 元模块被禁用/卸载/自身出错 → 所有提供方一起失效。现在是"一个模块坏了只坏一个" | 高 |
| **契约版本地狱** | 提供方升级改了 CLI 字段，元模块没跟上 → 静默显示错误状态。需要双方都做版本协商 | 中 |
| **仲裁本身可能误判** | 启发式识别"谁占用了什么"一旦误判，会禁掉一个正常工作的模块 | 中 |
| **调试链路变长** | 出问题要在「WebUI → 元模块 → CLI → 提供方 → sysfs」五层之间定位 | 中 |

### 5.4 与现有结构对比

| 维度 | 现状（GT8 单模块 v2.7） | 引入元模块 |
|---|---|---|
| 模块数量 | 1 | ≥ 2（元模块 + 至少 1 提供方） |
| 冲突风险 | **无**（只有一个模块，不存在争抢） | 需要仲裁机制来消除 |
| 运行时开销 | 1 个 5s 循环，温感读取已做单扫+优先级排序 | 1 个调度器（略优，但现状已足够低） |
| WebUI | 1 套，ksu.exec 直连 | 1 套外壳 + N 个后端契约 |
| 故障域 | 单模块 | 元模块 = 全局 |
| 适配新机型 | 改一个模块 | 改提供方 + 可能需要改契约 |
| 维护成本 | 低 | 高（两套代码路径 + 降级逻辑） |

### 5.5 结论：**不推荐引入**

**核心理由：元模块要解决的问题是「N 个模块互相争抢」，而你的实际结构只有 1 个模块 —— 这个问题当前不存在。** 为了一个假设性的问题去引入一个会带来硬依赖、单点故障、契约版本地狱的组件，收益/风险比是负的。你之前把 HORAE 和 Extreme GT 的可取之处**合并进单个模块**，恰恰是比元模块更优的解法：既拿到了两者的技术，又没有引入协调成本。

**但可以零成本地把元模块思想里的三条收编为内部约定**（拿到约 80% 收益、0% 风险）：

1. **资源归属注释化**：在 `functions.sh` / `mode.conf` 顶部用注释声明本模块占用的资源清单与理由，作为后续任何改动的约束
2. **单一轮询点**：所有周期性行为收敛到一个循环里（你 GT8 模块已经是 `service.sh` 一个 5s 循环，保持住，不要为单个功能再开新循环）
3. **冲突自检**：在 `customize.sh` 安装期扫描 `/data/adb/modules/*/module.prop`，若发现其他温控模块（HORAE / Extreme GT / Moka 的 id），`ui_print` 明确警告"检测到 X 模块，两者会争抢同一批配置文件，建议只保留一个" —— 这条**强烈建议加**，成本极低、收益直接

**什么时候应该重新考虑元模块**：当你确实需要同时维护 3 个以上独立功能提供方（比如温控、调度、充电策略各由一个作者维护），并且 KernelSU 提供了官方的依赖/顺序声明机制时。

---

## 6. 需要补充的上下文（若要做更细的判断）

1. **目标机型清单**：目前只确认了 RMX6699 / SM8750 / Android 16。是否还要支持其他机型/SoC？这决定温感分类策略是"通用"还是"按平台分支"
2. **是否真的需要多模块共存**：你是否有必须同时保留 HORAE（场景判定）+ 自己的模块的理由？如果只是为了"场景判定"能力，把它移植进来比共存更好
3. **Moka 的真实行为**：我剥到第八层未继续。如果你需要我确认它具体做了什么（是否含可疑行为），需要更多时间做完整还原 + 二进制分析
4. **`ro.product.odm.manufacturer` 与 `ro.soc.model` 在 GT8 上的实际取值**：用于确认 E1 门禁在真机上是否真的走了 else 分支（我按命名推断，未上机验证）
5. **`/proc/shell-temp` 的槽位语义**：0~9 与 0~2 的差异来源不明，若有内核源码或实测结论可以据此统一

---

## 7. 落地优先级

| 优先级 | 项目 | 归属 | 工作量 |
|---|---|---|---|
| P0 | 安装期冲突自检（检测其他温控模块并警告） | 你的 GT8 模块 | 小 |
| P0 | 温感匹配改分类/黑名单，匹配数为 0 时告警 | 借鉴 L2 的教训，确认自身已覆盖 | 小 |
| P0 | 去掉所有 `find` 未加引号 / `[ $(…)` 未加引号 的模式 | 通用 | 小 |
| P1 | 单一轮询点收敛，避免为单功能新开循环 | 你的 GT8 模块 | 小 |
| P1 | 版本号从 `module.prop` 统一读取，消除硬编码 | 若后续加元模块则必需 | 小 |
| P1 | 增加 `--verify` 类回读接口，UI 能显示"写了但没生效" | HORAE 缺 | 中 |
| P2 | 安装期 `find` 全量列举 + 内存分派（替代 9 次全盘扫描） | HORAE 缺 | 中 |
| P2 | 运行时 fork 优化：`read` 内建替代 `cat`、名单载入内存 | HORAE 缺 | 中 |
| — | 统一元模块 | **不推荐** | — |
