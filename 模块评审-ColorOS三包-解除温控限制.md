# 三个 ColorOS 去温控模块评审（对照真我GT8优化模块 v2.8.8）

> 评审对象
> - **A** `202507151356ColorOs解除温控限制-2.zip` — `id=ColorOs解除温控限制`，作者 CRUSHKK，12 项 / 4 KB
> - **B** `ColorOS移除服务级温控1.8.zip` — `id=ColorOS_remove_service_temperature_control`，作者 XmikN，15 项 / 16 KB
> - **C** `coloros解除温控限制😋_0.zip` — `id=LANDRINKMILK`，作者 LANDRINKJUICE，21 项 / 12 KB

---

## 总览：三条完全不同的技术路线

| | A（动态场景） | B（服务级） | C（配置全量改写） |
|---|---|---|---|
| 主手段 | `mount -o bind` 把写死的 40000 挂到 `thermal_zone*/temp` | 停 6 个服务 + 替换 `/data/oplus/os/bpm` 的 ELSA 墓碑配置 | 整份替换 4 个厂商配置文件，开关全关、阈值全 0 |
| 辅手段 | `/proc/shell-temp` 写 0–7、`/proc/game_opt/disable_cpufreq_limit`、`ctl.stop thermal-engine` | `/proc/shell-temp` 写 0–2（35000）、`system.prop` 11 条 | `/proc/shell-temp` 写 0–2（37000）、`system.prop` 9 条 |
| 循环 | `while :` + `sleep 1`，每轮最多 3 次 dumpsys | 无循环（service.sh 只执行一次） | `while :` + `sleep 60` |
| `uninstall.sh` | 有（但不完整） | **无** | **无** |

三者都会碰 `/proc/shell-temp`，但**写的值互不相同**（40000 / 35000 / 37000），槽位数也不同（8 / 3 / 3）。这正好印证本模块把 `OPPO_SHELL_TEMP` 默认设为 0 的判断是必要的 —— 这个接口的范围与语义在社区里根本没有共识。

---

# 一、可复用的部分

## ★1 三个模块登记进冲突库 Tier A（`common/conflicts.sh:match_known`）— 建议直接纳入

**它们与本模块争抢的是同一批资源，且都没有 uninstall 语义**：

| id | 争抢点 | 等级 |
|---|---|---|
| `ColorOs解除温控限制` | `/proc/shell-temp`、`ctl.stop thermal-engine`、`sys_thermal*` 覆盖 | high |
| `ColorOS_remove_service_temperature_control` | `stop horae` / `stop oppo_theias` / `stop orms-hal-1-0`（与本机 `DISABLE_ORMS` 对撞）、`/proc/shell-temp`、ELSA 配置 | high |
| `LANDRINKMILK` | 整份替换 `sys_thermal_control_config.xml` / `sys_thermal_config.xml`（与本模块 `PATCH_THERMAL` 的 bind mount 目标**完全同一路径**）、`/proc/shell-temp` | high |

其中 **C 与本模块的冲突最直接**：它 `mount --bind` 覆盖 `/odm/etc/temperature_profile/sys_thermal_control_config.xml`，本模块也 mount 同一个路径 —— 谁后挂载谁生效，卸载其中一个后另一个也失效。

改法（纯新增，不动现有分支）：

```sh
        ColorOs解除温控限制)
            echo "$1|$2|$3|high|争抢 /proc/shell-temp 与 thermal-engine 服务；其 mount 伪装 thermal_zone/temp 与本模块 emul_temp 叠加后读数不可预测"
            return 0 ;;
        ColorOS_remove_service_temperature_control)
            echo "$1|$2|$3|high|stop horae/oppo_theias/orms-hal-1-0 与本机 ORMS/horae 策略对撞；另整份替换 /data/oplus/os/bpm 的 ELSA 墓碑配置"
            return 0 ;;
        LANDRINKMILK)
            echo "$1|$2|$3|high|整份替换 sys_thermal_control_config.xml / sys_thermal_config.xml，与本模块 PATCH_THERMAL 的 bind mount 目标同一路径"
            return 0 ;;
```

名称兜底可加 `*解除温控*|*移除*温控*`（Tier B 的 `*温控*` 已能命中 A 与 C，但只到 medium）。

## ★2 `/data` 侧不止 `/data/system`：新增 `/data/oplus/os/bpm` — 建议纳入快照与登记

B 证明了第二个运行时配置目录的存在：`mount --bind .../sys_elsa_config_list.xml /data/oplus/os/bpm/sys_elsa_config_list.xml`。本模块 v2.8.7 只扫 `/data/system`，等于漏掉这一类（`sys_elsa_config_list.xml` 是 OFreezer/墓碑配置，含 `heatGameCloseNet` 等热相关开关）。

改法（沿用既有设施，只登记/快照、**不改写**）：

- `customize.sh` 的 `RUNTIME_SNAPSHOT` 目录列表增加 `/data/oplus/os/bpm`
- `KNOWN_CFG` 增加一行 `sys_elsa_config_list.xml`

理由与 v2.8.7 完全一致：这类文件被别的模块改坏、而对方又没有卸载脚本时，用户就再也回不去了。成本是几百 KB 快照。

## ★3 `bms_heating_config.txt` — 只登记，明确不改写

C 把它（`odm/firmware/fastchg/`）的全部字段写成 0，本模块的 `charging_*txt` 规则按文件名匹配不到它，属于漏项。

**但不要照抄 C 的改法**：它做的是"全字段归零"，包括 `0=enable`（enable=0）、`allow_temp_high_thr=0`、`temp_comp_*=0` —— 这是**关掉电池加热补偿功能**，性质上是禁用一个特性，不是抬高阈值；而本模块对 `charging_*txt` 用的是"+5°C"这种保守改写。两者策略不可混用，GT8 上也没有验证依据。

建议：`KNOWN_CFG` 加一行让它变成可见信息，改写规则保持不动。

## ★4 `feature_safety_optimize_enable_item` — 低成本补齐（可选）

C 把 `sys_thermal_control_config.xml` 的 4 个 boolean 全置 false，本模块只置了 3 个（`customize.sh:183` 的 `boolValues` 缺 `feature_safety_optimize_enable_item`）。这个字段语义是"温控安全优化"，置 false 与本模块目标同向。收益较小但风险同样小，可一并补上。

## ★5 只探测、不操作的两个新目标 — 建议进 `action.sh diag`

| 目标 | 出处 | 说明 |
|---|---|---|
| `/proc/game_opt/disable_cpufreq_limit` | A `service.sh:111`、B `service.sh` 注释 | OPPO 的"官方 FAS 限频"开关。B 特别注明"潘多拉内核已把 gameopt 干死"。本模块已有 `UNLOCK_FREQ`（写 `scaling_max_freq`），不需要它；但值得在诊断里显示"是否存在 / 当前值"，用于判断是不是别人在动 |
| `oppo_theias` 服务 | B `post-fs-data.sh` | 名字不含 `thermal`，本模块 `stop_thermal_services` 的 `grep -i thermal` 扫不到它。建议在诊断里列出其 `init.svc` 状态，**但不加入默认停止名单**（A16 上停未知服务风险大于收益） |

**明确不引入**：B 的 `stop fuelgauged` / `stop smartcharging` —— 直接动电量计与充电链路，与之前评审 Aurorawk 时定下的风险结论一致。

## ★6 一个可学的收尾写法：`sleep` 失败即清理

A 用 `sleep $SLEEP_INTERVAL || { 收尾; exit 0; }` 捕获终止（信号会打断 sleep 使其返回非 0），在被杀时把 `disable_cpufreq_limit` 写回 0、umount 温度节点再退出。

本模块 `service.sh` 是 `main_loop &` + `exit 0`，主循环被杀时没有任何收尾 —— 不过 `uninstall.sh` 与 5 秒重放兜住了大部分场景，所以这只是**可选的健壮性小改**，不是缺陷。

## 不复用（三处反面典型）

| 做法 | 出处 | 为什么不复用 |
|---|---|---|
| `mount -o bind` 把静态文件挂到 `thermal_zone*/temp` | A `manage_temp_mounts` | 比 `emul_temp` 重；sysfs 上 bind mount 在部分内核返回 EINVAL；值是写死的静态值，不随场景变化。本模块 `emul_temp` + 记账是更优解 |
| **目录级** bind mount：`mount --bind $MODDIR/odm/etc/ThermalServiceConfig /odm/etc/ThermalServiceConfig` | C `post-fs-data.sh:6` | 会遮蔽该目录下本模块未收录的文件（OTA 新增的、其它机型的），且失败无任何提示。本模块按文件 mount + `mounts.list` 记账更可控 |
| 整份替换他人机型的配置 | B 875 行 / 293 个包名的 ELSA；C 1189 行 `sys_thermal_control_config.xml` | 与"慕容模块"同类问题：跨机型、跨版本拼装。本模块只改键值、不动结构，正是为了避免这个 |

---

# 二、优化建议

> 针对三个包自身。按「问题 — 影响 — 改法 — 优先级」组织，均保持原有功能与对外接口不变。

## P0

| # | 问题 | 影响 | 改法 |
|---|---|---|---|
| A-1 | `while :` + `sleep 1`，每轮调用 `check_game_foreground`，该函数最多跑 3 次 `dumpsys`（`service.sh:40-61, 170-172`） | 每秒一次 dumpsys = 每天 86400 次 fork + Binder 调用，`dumpsys SurfaceFlinger` 尤其重；持续占用 CPU，与"改善触控响应"的目标本身相悖 | `SLEEP_INTERVAL` 改 3~5；三层回退改成"先探测一次可用的数据源并记住"；或直接用 `dumpsys activity activities` 一个来源 + `grep -m1` |
| A-2 | `grep -q "^[^#]*$current_app" "$GAME_CONFIG"`（`service.sh:56`） | 包名被当正则，`com.foo` 会子串命中 `com.foobar`；包名里的 `.` 也匹配任意字符，误判进入游戏模式 | 改 awk 精确比较（本模块 `is_in_list` 就是这么做的：`awk -F'#' '{... if ($1 == app) ...}'`） |
| C-1 | `setprop init.svc.thermal-engine stopped`（`service.sh:4-5`）每 60 秒一次 | `init.svc.*` 是 init 维护的**状态**属性，写它不会停止服务，init 下次状态变更还会覆盖回去 → 这行基本是空转 | 改 `setprop ctl.stop thermal-engine`（A 用的就是这个正确写法）或 `stop thermal-engine` |
| B-1 | **没有 `uninstall.sh`** | 卸载后：6 个被 `stop` 的服务（horae / oppo_theias / thermal_mnt_hal_service / orms-hal-1-0 / fuelgauged / smartcharging）不会自动回来，`/data/oplus/os/bpm` 的挂载也在，只能靠重启恢复 | 补 `uninstall.sh`：`start` 回这 6 个服务 + `umount` 挂载点；服务恢复用 `setprop ctl.start` 而不是写 `init.svc` |
| C-2 | `persist.sys.oplus.wifi.sla.game_high_temperature=`（`system.prop` 末行）**值为空** | 描述里写"温控墙为 52°"，实际注入的是空字符串，行为未定义（可能被消费方当成 0 = 一直高温） | 补上 52。本模块在 `customize.sh:133` 用 `setprop` 写 50，是同一思路的可用参照 |

## P1

| # | 问题 | 影响 | 改法 |
|---|---|---|---|
| C-3 | 目录级 bind mount（见上文）+ 4 个 mount 全部无返回值检查 | 目标路径不存在（GT8 上 `odm/firmware/fastchg/` 未必有）时静默失败，用户以为生效了 | 改成逐文件 mount 并检查结果，`|| echo "挂载失败 <路径>"` |
| C-4 | `set_perm_recursive $MODPATH 0 0 0777 0777`（`customize.sh:6`） | 整个模块目录（含以 root 执行的脚本）全局可写。与之前评审 Aurorawk 的 `chmod -R 777` 是同一类问题 | `0755 0644`，需要执行的脚本单独 `set_perm` |
| B-2 | 整份替换 ELSA 配置（875 行、293 个包名、`version 2025020600`） | 目标机的冻结/墓碑策略被完全替换成另一台设备的版本；冻结行为异常（该冻的不冻、不该冻的被冻）很难归因 | 只改需要的字段（`heatGameCloseNet`、白名单增删），保留原文件结构与版本 |
| B-3 | `system.prop` 里 6 条 `init.svc.*=stopped`（`init.svc.horae`、`init.svc.fuelgauged` 等） | 同 C-1：写状态属性不等于停服务，且 init 会覆盖；`post-fs-data.sh` 里已经用 `stop` 停了，这里是重复且无效的 | 删掉这 6 行，或保留但明确它是"占位"而非控制手段 |
| B-4 | `/proc/shell-temp` 只写 0/1/2 三个槽位（`service.sh:3`） | A 写 0–7、HORAE 写 0–9，槽位语义与数量在社区无共识；只写前三个可能覆盖不全，也可能这就是全部 | 至少在注释里说明依据；没有依据时按 HORAE/Extreme GT 的 0–9 对齐 |
| A-3 | `uninstall.sh` 只做 `umount` + `rm -rf` | `/proc/shell-temp` 的伪装值、`/proc/game_opt/disable_cpufreq_limit=1`、被 `ctl.stop` 的 thermal-engine 都没还原 → 卸载后仍处"已解除"状态 | 补：写 `disable_cpufreq_limit 0`、`control_temp_node Discharging`、`setprop ctl.start thermal-engine` |
| A-4 | `exit_game_mode`（`service.sh:129-133`）只在 `Discharging` 分支里 umount | 充电中退出游戏 → 温度伪装挂载保留，但 `game_active` 已置 0、日志却写"全部恢复系统默认状态"，日志与实际状态不一致，后续排查会被误导 | 按"退出游戏 → 回落到按电量状态决定"重写，让日志与实际动作一致 |
| A-5 | `mount -o bind` 到 `thermal_zone*/temp`（`manage_temp_mounts`）无任何记账 | 不知道哪些成功、哪些失败；`uninstall.sh` 只能盲 `umount` 通配 | 成功的路径写进 list，卸载时按 list 还原（本模块 `mounts.list` 即是这个作用） |

## P2

| # | 问题 | 影响 | 改法 |
|---|---|---|---|
| A-6 / C-5 | `module.prop` 用 **`versioncode`**（小写 c） | Magisk/KSU 读的是 `versionCode`，小写键被忽略 → 版本永远显示为空、也无法比较升级。A 与 C 都中招，B 用的 `versionCode` 是对的 | 改成 `versionCode` |
| A-7 | `id=ColorOs解除温控限制`（非 ASCII id） | 模块目录名 = id，中文目录在部分管理器/脚本/ADB 场景下处理异常 | id 用 `[a-z0-9_-]`，中文放 `name` |
| C-6 | `service.sh` 无 shebang、无 `MODDIR`、循环无退出条件 | 与 A 的"sleep 失败即收尾"对比明显；被杀时无清理 | 补 `#!/system/bin/sh`，循环加收尾分支 |
| A-8 | `control_temp_node` 里前 7 行 `>` / `>>` 混用，只有最后一行带 `2>/dev/null` | 风格不一致，且前 7 行失败会打进安装/运行日志噪音 | 统一写法 |
| 共性 | 三者都无条件写 `/proc/shell-temp`，值各不相同（40000/35000/37000） | 该接口与屏幕亮度直接相关（本模块 v2.3 的实机结论），HORAE 与 Extreme GT 都用 29500（29.5°C）；40°C/37°C 属于**高于真实**的注入方向，可能触发厂商"温热降亮度 / HBM 退出" | 若坚持要写，方向应与成熟模块一致（低于真实），而不是高于 |

---

## 建议的落地顺序与验证方式

**本模块侧（本次只出建议，未改代码）**

1. ★1 登记三个 id → 验证：装任意一个后 `sh action.sh conflicts` 应报 high 并给出争抢说明
2. ★2 扩 `/data/oplus/os/bpm` → 验证：安装日志出现快照条目；`ls /data/adb/thermal_remove/runtime_backup/`
3. ★3/★4 登记与补齐 → 验证：`sh action.sh diag` 的"已知配置核对"段能看到 `sys_elsa_config_list.xml` / `bms_heating_config.txt`

**若要改这三个包**

- A-1：`top` 观察 service.sh 的 CPU 占用，改动后应从持续可见降到接近 0
- A-2：在 game 列表里放 `com.foo`，前台切到 `com.foobar` 不应进入游戏模式
- C-1/B-3：改完后 `getprop init.svc.thermal-engine` 应为 `stopped` 且 `ps -A | grep thermal` 无进程（改前是有进程的）
- B-1/C-6：卸载后不重启，`getprop init.svc.horae` 应回到 `running`
