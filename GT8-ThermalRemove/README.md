# GT8 ThermalRemove v2.15.2

针对 **真我 GT8（RMX6699 / 骁龙 8 至尊版 SM8750，平台代号 sun）** 的 SukiSU（KernelSU）温控模块。
适配 **Android 16 / realme UI 7.0（RMX6699_16.0.0.263 CN01）**，已在实机安装验证。

> 平台说明：早期版本按传闻写作 SM8850；**实机安装日志显示 `ro.board.platform=sun / ro.soc.model=SM8750`**，
> 即骁龙 8 至尊版（第一代至尊版的 SM8750），已按实测更正。

## 版本演进

模块参考 **HORAE Extreme** 与 **Extreme GT** 两个成熟模块重构而成，核心思路从
「停服务 + 清空配置」改为「**温度欺骗为主、阈值改写为辅**」（前者温和有效，后者作为补充）。

| 版本 | 要点 |
|---|---|
| v2.0 | 主策略改为 `emul_temp` 温度欺骗；安装期改写 OPPO/realme 私有温控阈值 |
| v2.1 | 补 OPPO 私有手段（HORAE testmode / ORMS 停用 / GPU lock_val） |
| v2.2 | **修复 WebUI 完全不可用**（管理器不执行 CGI，改走 `ksu.exec` root 直连）；<br>**修复亮度被锁在最低的回归**（OPPO 私有手段默认全关） |
| v2.2.1 | 按实机安装日志更正机型识别（RMX6699 / 平台 sun / SM8750） |
| v2.3 | **定位亮度锁最低的真正原因**：默认不再归零 `cooling_device`（会误伤背光类节点），<br>显示类节点永久保护，皮肤欺骗温度降到 29.5°C |
| v2.3.1 | 修复 WebUI 日志 JSON 报错（清除控制字符 + 原文降级） |
| v2.4 | 实时温度精简为「关键温感」，单次扫描替代嵌套循环（几百次 fork → 几十次） |
| v2.5 | WebUI 改版（大标题 + 状态卡 + 六宫格磁贴 + 统计卡），欺骗温度输入改为摄氏度 |
| v2.6 | 实时温度同时显示「伪装值 / 真实值」 |
| v2.7 | 真实温度改为**仅手动刷新**（按钮 / 下拉 / 重试），带缓存、超时、失败态 |
| v2.8 | 新增**模块冲突自检**（安装期 / 运行时 / WebUI 三入口）；开机自检并入唯一轮询循环 |
| v2.8.1 | 修复真实温度探测：读数必须与伪装值不同才算数，否则加长重试；探测残留自愈 |
| v2.8.2 | **修复根因**：部分高通内核 `emul_temp` 回读恒 0 → 「欺骗中」判定改用模块记账 `spoof.list`；<br>版本徽标改为实时读取 `module.prop` |
| v2.8.3 | 并入显示 / 触控端到端延迟调优（`system.prop` 注入 Adreno / SF / HWUI / InputReader 属性） |
| v2.8.4 | **修复安装期温控改写从未生效**：`xml_override` 多行键值表处理错误导致 patched 写成空文件；<br>另修 WebUI 保存含 `/` `&` 的值失败、路径正则误判、配置解析重复与主循环重复解析 |
| v2.8.5 | **修复「欺骗校验永远失败」误报**（实机日志：83 个温感已应用成功却判定失败）——期望值取错来源 + 行首匹配过严 + 小数位假设；改用记账 `spoof.list` 为判据，horae 降级为诊断参考 |
| v2.8.6 | 冲突自检新增 **Tier C「按资源占用扫描」**（认不出身份时改看第三方模块写了哪些资源，`SCAN_RESOURCES` 开关，默认关）；<br>登记「慕容 ColorOS 附加模块」为已知冲突（清空高通 perf boost + 全局锁 120Hz，与目标相反）；<br>`action.sh diag` 增补第三方显示/亮度嫌疑排查；`system.prop` 以注释形式收录两条待验证的触控手势参数 |
| v2.8.7 | 横评第三方模块后**补齐漏扫的 2 类厂商配置**（`refresh_rate_config.xml`、`sys_resolution_switch_config.xml`）—— 只登记不改写（理由见下）；<br>新增 `/data/system` **运行时副本快照**（`RUNTIME_SNAPSHOT`）：别模块 `sed -i` 改坏又无卸载脚本时可一键还原（`action.sh rr_restore`），快照在卸载本模块后仍保留；<br>`action.sh diag` 新增「运行时副本一致性」与「已知配置核对」两段 |
| v2.8.8 | 触控新增 **`inputflinger` 线程级提权**（`TOUCH_THREAD_BOOST`，默认关）：补上 `TOUCH_BOOST` 漏掉的半程 —— 事件分发其实在 InputReader/Dispatcher/Classifier 线程上；<br>**只用 nice，不用 SCHED_FIFO，也不碰 `sched_rt_throttle_us`**（第三方包的「FIFO 99 + 关 RT 节流」是整机硬卡死组合），原值备份可精确还原；<br>新增 `action.sh touch` 体检入口 |
| v2.8.9 | **修复 `diag` 第三方显示配置覆盖的假阳性**：原判定用「文件非空」，而原厂这些文件本就非空 → 每次必报 4 个 ⚠；改为查 `/proc/mounts`（只有 bind mount 才造成覆盖），并**直接打印源模块路径**；<br>`diag` 新增「显示配置内的亮度限制字段」：解析 `oplus_vrr_config.json` 的 `hw_nit_limit` / `hw_nit_limit_pwm`（硬件层 nit 上限，非 0 即「亮度拉不上去」的直接成因，此前排查面完全没覆盖）；<br>登记「ColorOS 显示优化」为已知冲突（整份替换 VRR 配置，档位上限 120Hz，GT8 是 144Hz 面板） |
| v2.8.10 | 代码审核后修正 v2.8.9 的三处边界：<br>**① 补上目录级 bind mount 检测** —— v2.8.9 只认「挂载点 = 该文件」，而模块 bind 整个 `/my_product/etc` 时挂载点是**目录** → 漏检（漏检比误报更糟：会让人直接排除掉真正的嫌疑源）；改为「挂载点 = 该文件**或其祖先目录**」并只认源在 `/data/` 下的挂载，同时标明文件级/目录级；<br>**② 修正字段取值** —— 字符串 `"0"` 不再误报成「未设置」，小数 `0.5` 不再被截断成 `0` 而漏报真实的亮度钳制；<br>**③ 文档与实现对齐** —— 明确写出这一段**查不出** magic mount（overlay）与 `sed -i` 原地改写，别把否定结论当定论 |
| v2.8.11 | **修复 `diag` 温感段永远空白（P0）** —— `dump_temp()` 把循环变量 `$_z` 误写成 `$z`，`[ -e "/temp" ]` 恒为假导致每个 zone 都 `continue`。核心功能不受影响（`apply_spoof` 用的是正确变量），但「温感是否在欺骗」在诊断输出里根本看不到；<br>**VRR 亮度字段改判据** —— 实机发现 GT8 **原厂 `hw_nit_limit` 就是 50**，v2.8.10 的「非 0 = 被钳制」在没刷任何模块时也天天报 ⚠；且该值与 `dumpsys` 的 `mMinimumBrightnessCurve` 同样是 50/90，说明是亮度曲线百分比而非 nits。改为**与安装期原厂基线比对**，缺基线时不做判定 |
| v2.8.12 | **主循环开销优化（实测单轮 fork 68 → 4，降 94%）**：`load_conf` 由 25 次 `conf_get`（每次 sed+head）改为纯 shell 一次遍历 → 50 fork 归零；`decide_state` 加条件闸 —— 保护/游戏列表无可命中条目时**不再调用 `get_focus_app`**，默认配置下那每 5 秒一次的重型 `dumpsys activity activities` 彻底消失；`get_charging` / `reapply_perf` / `service.sh` 改用内建 `read` 与 `${f%/*}` 取值，`reapply_perf` 值已正确时不再重写 sysfs；<br>**顺带修 3 个缺陷**：`diag` 侧 `while read` 会丢弃无尾换行的最后一行（配置被静默忽略）；`_strip` 不剥离 `\r` —— CRLF 配置会让 `UNLOCK_FREQ=1` 这类判定恒假、开关静默失效；`get_focus_app` 只匹配 `topResumedActivity=`，字段名不符时每轮跑两次 dumpsys |

| v2.9 | **省电优化：把「检测周期」与「维护周期」拆开**（主循环 fork 实测降 96%，见 `省电优化-v2.8.13.md`）：原本每 30s 跑一次**全量** `apply_state`（find + 逐文件 awk + 逐核 `sysfs_set` + 83 个温感的 `cat` + `pidof` ≈ 177 次 fork），而状态没变时其中绝大多数是空转；现拆成 **5s 检测**（只做零 fork 读取，安全侧响应不变）+ **120s 轻维护**（`maintain_state`，只重放欺骗值/压制频锁/补提权/校验挂载）；<br>配套落地：`apply_spoof` 的 `cat`/`$(zone_target)`/`basename` 全部零 fork 化、欺骗日志去重（一天 2880 行重复记录 → 约 60 行）、配置与列表按 mtime 缓存（带 60s 强制刷新兜底）、`sysfs_set` 备份索引改进程内缓存、挂载校验合并成一次 awk、开机等待退避、WebUI 心跳 1s→5s 且自动刷新 30s→60s；<br>**新增 6 个可调项**：`MAINT_SECONDS` / `PERF_REFRESH_SECONDS` / `LOG_HEARTBEAT` / `CONF_FORCE_TICKS` / `UNLOCK_GPU` / `GPU_MAX_CLK`（设 `MAINT_SECONDS=30` 即回到 v2.8.12 节奏；老配置里的 `RES_SPOOF_TICKS` 会按 tick×5s 自动折算）；<br>**审核后修复（versionCode 45）**：补回周期维护丢失的 `scaling_min_freq` / GPU devfreq `max_freq` 压制（否则 GPU 降频后不再恢复）；修复 WebUI 状态刷新失败时退化成请求风暴；欺骗重放全失败时提前重试自愈；新增 GPU 独立开关与频率甜点值以平衡功耗/发热；<br>**可维护性收尾（versionCode 46）**：修复跨进程缓存时间戳竞态（`CONF_PERSISTENT` 标志，只有长驻守护打 stamp，`action.sh` 等一次性进程不再干扰主进程的配置变更检测）；`dump_temp`/`dump_cdev` 诊断路径零 fork 化（`action.sh diag` 从 ≈170 次 fork 降到 ≈0）；文件头部集中登记运行时状态变量索引；<br>**真实温度探测修复 + 日志导出（versionCode 47）**：修复「读取真实温度后欺骗失效」——探测结束时按记账 `spoof.list` 全量重放一遍欺骗值，避免某温感写回失败/被并发覆盖后停在 0（此前要等 120s 维护周期才兜底）；WebUI 诊断区新增「导出日志」按钮，一键下载完整运行日志（`gt8_thermal.log`）便于离线排查；<br>**导出落盘到 /sdcard/Download（versionCode 48）**：导出改为 root 后端直接复制到 `/sdcard/Download/gt8_thermal_<时间戳>.log`（浏览器下载目录不可控），失败自动降级为浏览器下载；<br>**CPU 频率限制（versionCode 49）**：新增「CPU 性能模式」二态开关（`CPU_LIMIT_MODE` 0=游戏满血/1=日用控温）——日用模式把超大核（prime）封到 `LIMIT_PRIME_MHZ=2246`、大核（perf）封到 `LIMIT_PERF_MHZ=1996`，**不调整 GPU**；按 `cpuinfo_max_freq` 动态区分 prime/perf（骁龙 8E 2+6 拓扑，无需硬编码），写上限自动对齐到 ≤ 目标的最近档位；切换入口 `sh action.sh daily`/`game` + WebUI 单选；<br>**CPU 限频修复（versionCode 50）**：修 `cpu_topology`/`_freq_best_into`/`gpu_cap_target_into` 内部循环变量与外层同名导致写错路径（真机表现为 scaling_max_freq 停在最低档）；档位对齐由「严格 ≤ 目标」改为「就近四舍五入」（1996→1996800、2246→2246400，误差 <1MHz）；<br>**v2.9 正式版（versionCode 51）**：由 v2.8.13 阶段性版本号收敛为 v2.9；<br>**CPU 限频抢回修复（versionCode 53）**：`stop_thermal_services` 补充 realme/OPPO 实机 perf/调度守护进程名（`thermal-engine-v2`、`perfservice`、`vendor-oplus-hardware-performance-V1-service`、`perf2-hal-1-0`、`oplus_sched`/`oplus_sched_rename` 等）——这些进程读自有温度估算、不走 emul_temp 欺骗路径，会把大核 scaling_max_freq 实时压回最低档，导致日用限频被抢；其中 perf/调度守护进程是 init `exec` 直接拉起、`ctl.stop` 报 "Unable to stop service" 且无效，改为按进程名 `kill -9` 兜底；设 `STOP_SERVICES=1` 后即可钉死 CPU 限频；<br>**电池欺骗默认开启（versionCode 54）**：`SPOOF_BATT` 默认值由 0 改为 1（电池/USB 温感一并欺骗）；dynamic 模式下充电仍会自动跳过，always 模式请自行承担充电过温风险（硬件级熔断兜底）；<br>**v2.9.1 版本号规范（versionCode 54）**：正式启用三段 SemVer（主版本.次版本.修订版本），v2.9.1 即本轮修复批次；此后每次改动按语义进位 + `versionCode` 独立单调递增；<br>**v2.9.2 移除 CPU 限频 + 修复频锁不可逆（versionCode 55）**：CPU 频率限制功能实机未达预期（realme/OPPO 的 `perfservice` 等 exec 拉起进程会持续把大核压回最低档，30s 压制抢不过它们），**整体移除** `CPU_LIMIT_MODE` / `LIMIT_PERF_MHZ` / `LIMIT_PRIME_MHZ` 三个配置项、`cpu_topology` / `_freq_best_into` / `cpu_max_cap_into` 三个函数，以及 `action.sh daily|game` 快捷命令与 WebUI「CPU 性能模式」单选；CPU 上限恢复为「恒等于 `cpuinfo_max_freq`」（随 `UNLOCK_FREQ` 总开关），即 v2.8.12 语义，**其余功能与接口行为不变**；<br>**修复真实缺陷**：`lock_val` 原先对 GPU 节点 `chmod -w` 后既不备份原值也不记录被锁节点，导致卸载模块或 `UNLOCK_GPU` 1→0 切换后节点仍是只读、值仍是解锁后的状态，只能靠重启恢复（且 `restore_sysfs` 的备份链压根不覆盖这些节点）。现首次锁定时备份原值到 `gpu_lock.bak`，新增 `restore_locked_nodes` 在 `restore_sysfs` 末尾与 `UNLOCK_GPU=0` 时解除只读并写回原值；<br>**去重**：GPU devfreq 上限压制原先在 `unlock_perf` / `reapply_perf` 里各写一遍，抽出 `gpu_devfreq_cap` 统一（`bak` 带备份 / `raw` 值相同跳过，语义不变）；<br>**v2.9.3 source 副作用闸门 + api.sh 修复（versionCode 56）**：①**修复真实缺陷**——`functions.sh` 的建目录/日志轮转是 source-time 语句，被 `api.sh` 的 `get_verify` 一并触发，导致点「校验欺骗」可能把 >256KB 的日志清空；现加 `TR_SIDE_EFFECTS` 闸门，默认关，只有 6 个写盘入口显式开启；②api.sh 零 fork 化（`get_temps` 温感扫描 + 真实温度探测循环 + 充电检测 + `do_set` 的 K=V 解析，合计省去每次请求数百次 fork）；③修复 `SKIN_T` 默认值漂移（api.sh 33000 → 29500，与 spoof.conf/functions.sh 一致）；④版本徽标改由 `get_status` 带出，取代写死的 `FALLBACK_VER`（原停在 v2.8.2）；⑤`get_log_full` 去掉多余管道、真实温度探测回写改 `mv`；<br>**v2.10.0 日志分级 + 诊断包（versionCode 57，新增功能故走次版本号）**：①**日志分级**——4 级 `DEBUG/INFO/WARN/ERROR`，阈值由 `LOG_LEVEL`（mode.conf 或 WebUI 下拉）控制，行格式 `[MM-DD HH:MM:SS] [LVL] 正文`，可按 `grep '\[WRN\]\|\[ERR\]'` 过滤；低于阈值的日志**连行都不拼**（连 `date` 都不执行），即 DEBUG 在 info 阈值下零成本；配置写错一律回落 info（宁多打日志也不让日志静默消失）；36 个调用点已按语义分级（8 debug / 20 info / 4 warn / 1 error），`log_print` 保留为 info 的兼容别名；②**诊断包导出**——`action.sh diagpack` 或 WebUI「导出诊断包」一键收集 6 节（设备/系统、配置全文、运行状态与记账、温感+冷却设备+关键 sysfs、模块冲突、分级日志尾部），打包为 `/sdcard/Download/gt8_thermal_diag_<时间戳>.tar.gz`（无 tar 时降级为单 `.txt`，内容一字不少），纯只读收集、不改任何模块状态；<br>**v2.10.1 诊断包分析驱动的修复（versionCode 58）**：靠真机诊断包（2026-10-05）一次性定位 4 个问题 —— ①**冲突检测漏报**：`scan_resource_hits` 只 grep 脚本字面量，Scene 这类「编译体+配置」的工具扫不到、已知库也没收录，实测漏掉了 `scene_systemless`(判 high)、`muronggameopt`/`fopbatt`/`adreno_gpu_driver`(medium)，已扩 `match_known`（刻意不用 `*batt*` 宽通配以免误伤 `combat` 等）；②**早期日志时间戳错乱**：post-fs-data 阶段 RTC 未同步，`date` 返回 1970 年附近值，日志里混入"1970 年的记录"导致排序错乱，改为时钟未就绪时用 `[BOOT +N]` 标记（顺带省掉这些行的 date fork）；③诊断包的 `emul_temp` 字段真机回读为空（无诊断价值）→ 改为「记账值 + 回读」并排并加说明；④SukiSU 版本探测扩展到 7 个候选属性 + `/data/adb/ksu/version` 兜底；⑤**新增「CPU 频率三级对照」**（硬件极限 / 本模块改写前备份 / 当前）——正是这张表揭示了设备上"有第三方工具在锁 CPU 高频（备份前超大核 min=max=3072000）"；<br>**v2.10.2 更名（versionCode 59）**：模块显示名、包名与 WebUI 标题由「真我GT8优化模块 / RealmeGT8-SukiSU-ThermalRemove / GT8 温控移除」统一为 **GT8 ThermalRemove**；`id` 保持不变（`realme-gt8-sukisu-thermal-remove`）——id 是 KernelSU 识别模块的唯一标识，改动等于换模块，必须卸载重装且设备端路径会全部失效；<br>**v2.10.3 第三方模块名含 `|` 的净化 + 日志修正（versionCode 60）**：①**真实缺陷**——冲突检测用 `|` 分隔字段，而第三方模块的 name 就含 `|`（实机证据：`adreno_gpu_driver` 的 name 是 `Adreno™ 8xx GPU Drivers （ANGLE|Game driver）`），导致输出行 5 段变 7 段、下游 `IFS='|' read` 全部错位：日志打成 `⚠ 冲突模块[Full]: … — v2.0|medium|…`、WebUI 冲突卡片的风险色与备注被截断；现读入时即净化（`|`/CR/LF → `/`），下游一律安全；②**冲突日志瘦身**——原实现把整行（含上百字备注）塞进日志，一次开机刷数行超长 WRN，淹没真正的状态变更；现只记「风险级别 + 模块身份」并汇总条数，完整备注留在 WebUI 与 `action.sh conflicts`；③**api.sh 日志补级别标签**并尊重 `LOG_LEVEL` |
| v2.11.0 | **场景预设档 + WebUI 温感树（versionCode 61）**：①**场景预设档** —— 新增 `presets/` 目录（`stock` 原厂 / `daily` 日用均衡 / `game` 游戏满血 / `cool` 降温优先 / `debug` 排障）与 `common/presets.sh` 引擎，WebUI 顶部一卡一档、点一下切换；**局部覆盖**语义：一个档只接管自己声明过的键，`BLACKLIST`、真实温度开关等个性化设置永不被改写；每个键过白名单、每个值过取值校验，非法项静默丢弃；「已应用 / 最接近 X / 自定义」由**无状态匹配度**推出，手改任一开关后界面立刻如实变化；命令行 `sh action.sh preset` 可列出与切换。②**WebUI 温感树** —— 按功能域（CPU/GPU/电池/外壳/相机/内存/射频/音视频/电源/显示/传感器）把全部温感组织成「分类 → 叶子」两级树，分类节点聚合「欺骗 n/m · 最高 x°C」，叶子行给出「类型 / 伪装值 / 真实值 / 欺骗类别 / 为什么没被欺骗（命中黑名单·电池欺骗已关·内核不支持 emul_temp）」；叶子与整组都能一键加入/移出 `BLACKLIST`（走专用 `--setlist` 通道，值里的空格与 `*` 原样保留）。③**分类映射只在后端算**（`get_temps` 输出 `grp/cls/tgt/ex`），前端只做展示 —— 回归套件里有一条「拿 16 个真机温感名，把 `cls→目标温度` 与 `functions.sh` 的 `zone_target_into` 逐条对拍」的断言，正是它在开发期抓到了「电池类判定过宽、界面会显示模块根本不会写的目标温度」这个偏差。④**修掉一个既有真实缺陷**：前端 `cgiJson()` 从未把 query 拼进 URL，而 busybox httpd 靠 `QUERY_STRING` 分派 —— 走内置 httpd 通道时每个请求都落到「未知操作」，界面完全读不到数据（只有 ksu.exec 通道正常，所以一直没暴露）。现 query 与 POST 的 `action=set` 都补齐。⑤`ui_test.js`（Node + DOM 桩）34 项断言覆盖预设三态渲染、树聚合与顺序、真实温度联动、黑名单增删、CGI URL 拼装；<br>**v2.11.1 遗留问题清理（versionCode 62）**：①`customize.sh` 升级路径显式清理已废弃的 `CPU_LIMIT_MODE`/`LIMIT_PERF_MHZ`/`LIMIT_PRIME_MHZ` 键（v2.9.2 起移除该功能），并 ui_print 提示；②`mode.conf` 的 `STOP_SERVICES` 注释补明 v2.9 起会对 perf 守护进程做 kill 兜底（默认仍关闭，需按需开启并观察）；③诊断包「关键 sysfs」段补 `max_gpu_clk`/`max_clock_mhz` 实读值，并注明这两个是 legacy 接口、SM8750 真正压制频率的是 devfreq `max_freq`，改 `GPU_MAX_CLK` 甜点值后应以 `devfreq/cur_freq` 为准确认哪个节点真生效；<br>**v2.11.2 安全修复（versionCode 63）**：①**修复 WebUI httpd 通道的跨源写入（CSRF）** —— 原实现 `Access-Control-Allow-Origin: *` 且写接口无来源校验，httpd 运行期间同设备浏览器里的任意网页可对 `127.0.0.1` 发 simple request（不触发 preflight）静默改写 root 级配置（`MODE`/`SPOOF_BATT`/黑名单、反复触发真实温度探测）；现对 `action=set`/`setlist`/`preset`/`temps real=1` 四个写分支统一做 Origin/Referer 校验：仅放行同源（127.0.0.1/localhost）与不携带 Origin 的请求（ksu.exec 直连、老 WebView、浏览器直接打开页面均不受影响）；②诊断包导出失败时错误消息过 `_jesc` 转义，含引号的报错不再让前端 JSON 解析失败而丢失失败原因；③`do_set` 无任何键真正落盘时如实返回「没有可保存的项」，不再误报「已保存」<br>**v2.12.0 安全兜底与自救（versionCode 64）**：①**温度保险丝**（`FUSE_ENABLE`，默认开）—— 每维护周期（120s）采一轮关键温感的**真实温度**（短暂写 `emul_temp=0` → 读 `temp` → 立刻写回伪装值，复用 `REAL_ZERO_MARK` 自愈标记），电池 / SoC / 外壳三路阈值（默认 45000/80000/46000 毫摄氏度，可设 0 关闭单路）任一越界即撤销欺骗、回原厂保护，并在 `FUSE_COOLDOWN`（默认 120s）内拒绝重新移除温控 —— 冷却由 `decide_state` 直接返回保护实现，否则 5s 检测层会立刻把刚撤掉的欺骗重新打开、来回抖动；触发记录追加到 `/data/adb/thermal_remove/fuse.log`，`sh action.sh fuse` 查看，WebUI 状态含 `fuse_trips`。②**一键安全模式 / 开机自救** —— `sh action.sh panic` 立即撤销一切改写并置 `MODE=off`；另加 boot token：连续 `BOOT_FAIL_LIMIT`（默认 3）次开机没有走到 boot-completed 就自动进入安全模式（宁可少一次去温控，也不要卡开机），`sh action.sh dynamic` 退出并自动清除标记，`action.sh status` 与 WebUI 状态带出 `safe_mode`。③**遗留修复** —— post-fs-data 早期阶段改按 `decide_state` 决定是否移除温控（原实现硬编码移除，`dynamic` + 开机时插着充电器会在主循环接管前的 20~60s 窗口里缺失充电过温保护）；`stop_thermal_services` 的 kill 段改走 `pidof` 优先 + `ps` 按表头定列（原实现硬取第 2 列，在 busybox `ps` 上拿到的是 USER 名，kill 静默失效）；`get_status` 的外部来源字段（state / version / model / android）统一过 `_jesc`；温感 `type` 含 `|` 或 `"` 时净化（第三方 bind mount 伪造值不再让界面 JSON 非法）；`boot-completed` 顺带清理 CGI 遗留的 `gt8_*` 临时文件（只清本模块前缀且 2 小时以上未修改的）。<br>**v2.13.0 一键体检（versionCode 65）**：新增 `doctor` —— 一条命令/一个按钮给出「环境是否支持 + 当前是否生效 + 有哪些风险」的 8 节纯文本报告（设备版本 / 内核能力 / 温感命中 / 欺骗状态 / 冲突检测 / 配置与保险丝 / 安全与风险 / 依赖权限），全程只读、不改任何状态；`sh action.sh doctor` 或 WebUI「体检」按钮触发，结果可直接复制用于反馈问题；风险节会主动提示「always + 电池欺骗」「保险丝关闭」「安全模式」等高危组合。<br>**v2.13.1 写回执（versionCode 66）**：保存配置后 6.5s 自动回拉状态面板，比对本次写入的键是否真的生效——已生效显示「✔ 已生效：N 项均已写入」，未生效则列出键名并指向「冲突检测」（可能被其他模块/服务覆盖）；状态面板未暴露的进阶键（MAINT_SECONDS 等）自动跳过、不误报。<br>**v2.13.2 配置 schema 单一事实源（versionCode 67）**：新增 `common/schema.sh`，把配置键的「归属文件 / 默认值 / 值域校验 / 预设可接管性」集中到一处；`load_conf` 的默认值初始化、`do_set` 的白名单与值校验、预设引擎的 route/valid/default 全部改为查 schema —— 今后新增配置键只需改 schema.sh 一个文件，根除「三处白名单手动同步」带来的漏改与默认值漂移（本版本顺带修复 do_set 不再接受非法值，界面与运行时行为保持一致）。<br>**v2.13.3 诊断包补保险丝节（versionCode 68）**：`build_diagpack` 新增 `07-fuse.txt`，输出温度保险丝开关/阈值/冷却/累计触发次数 + **三路真实温度**（电池/SoC/外壳，短暂写 `emul_temp=0` 采真值后按「原值」写回 —— 无论当前是否处于欺骗态都安全，不会把未欺骗的温感意外开启欺骗）+ 触发记录 + 安全模式/boot token 状态；`sh action.sh fuse` 一并升级为同一份报告。此前诊断包缺失这一节，导致保险丝采样是否在跑、真实温度离阈值多远完全不可见。<br>**v2.14.0 函数库拆分（A3，versionCode 69）**：`common/functions.sh` 从 1781 行单文件拆为「聚合入口 + 8 个功能域库」—— `log.sh`(日志) / `config.sh`(配置+sysfs 备份) / `spoof.sh`(温度欺骗) / `perf.sh`(频率锁+GPU+触控+温控服务) / `system.sh`(挂载+属性+ORMS) / `state.sh`(状态决策) / `fuse.sh`(保险丝+安全模式) / `doctor.sh`(体检+诊断)。**行为完全不变**（79 个函数逐一按域搬迁、函数总数守恒），所有入口仍 `source functions.sh`即可，无需改动调用方；为后续 L1 统一框架「抽 framework/ 与小米线共用骨架」铺路。<br>**v2.14.1 修复真实温度探测破坏欺骗（versionCode 70）**：真机诊断发现 `_fuse_read_one` 用「回读 emul_temp 原值」做恢复，但本内核 emul_temp 回读恒为空 → 原值误判为 0、写回 0 撤销了该温感欺骗。改为用 `zone_target_into` 算伪装值写回（与保险丝采样 `_fuse_probe_one` 一致），并在三路探测结束后按记账全量重放兜底，确保欺骗立即恢复、不留下「欺骗被撤销」窗口。<br>**v2.14.2 冲突卡片紧凑展示（versionCode 71）**：WebUI 冲突列表默认每项只占一行（风险徽章 高/中/低 + 模块名 + 版本），模块 ID 与长备注收进点击展开区 ——多个冲突模块原来整卡要占一屏多，折叠后一屏内看完；仅 high 级别默认展开（最需要处理的信息不藏在点击后面），标题带「共 N 项」计数。完整备注仍可从`sh action.sh conflicts` 与诊断包 05-conflicts.txt 获取，信息不丢失。<br>**v2.14.3 修复保险丝电池路选错温感（versionCode 72）**：真机诊断发现电池路选到了 `usb`（读到 3.1°C 异常低温）而非 `battery`，因为原来把 `*usb*` 与 `*battery*` 并列「取首个」、而遍历顺序 usb 先于 battery，导致电池过温保护（阈值 45°C）永远不触发。改为 battery 优先、usb 仅在无 battery 时兜底。<br>**v2.15.0 按前台应用自动切档（F4，versionCode 73）**：新增 `AUTO_GAME_PRESET`（默认关）——开启后每 30s 检测前台应用，命中 `game_list.conf` 里的游戏自动应用 `game` 档，退出游戏（连续约 90s 非游戏，防切桌面回消息时抖档）后恢复切档前最接近的那一档（匹配度 &lt;50% 视为完全自定义，退出时不覆盖）；检测节奏独立于 5s 温控检测，避免每 5s 跑一次重型 dumpsys。<br>**v2.15.1 修复诊断包温度显示（versionCode 74）**：`dump_temp` 原来只在值 ≥10°C 时把毫摄氏度除以 1000，否则原样显示 —— 于是 `SPOOF_BATT=0` 时 usb 这类真实温度3.3°C（3300 毫摄氏度）的非欺骗温感被显示成「3300°C」。改为统一保留一位小数（3.3°C），与保险丝三路真实温度显示一致。<br>**v2.15.2 game_list 增补（versionCode 75）**：`game_list.conf` 新增 `com.mpsgame.lostabyss`（生贽之尖）——开启 `AUTO_GAME_PRESET` 后，该游戏进入前台会自动切 game 档。 |

> 详细演进过程与设计取舍见 git 历史或早期版本包。

---

## ⚠️ 风险警告（务必先读）

| 风险 | 说明 |
|---|---|
| 机身温度显著升高 | 重载（游戏 / 录像 / 跑分）下背板可能烫手 |
| 电池加速老化 | 锂电池长期高温循环明显损耗容量 |
| 硬件损伤可能 | 极端情况可能损坏 SoC、屏幕、电池 |
| 失去保修 | 解锁 BL + root 后官方保修通常失效 |
| 稳定性下降 | 长时间满频可能触发重启、闪退 |

- 刷入前 **务必备份 `boot` / `init_boot` 分区**，确认能进 Recovery。
- **SoC 硬件级过热保护（Tj）无法被软件移除**，撞到结温仍会强制降频/关机。这是最后的保命线。
- 默认配置已内置一层保护：dynamic 模式下**充电时自动恢复原厂温控**。

---

## 设计取舍（为什么这么做）

| 决策 | 理由 |
|---|---|
| 用 `emul_temp` 欺骗而非停 thermal 服务 | 停 HAL 会影响温度上报、清空配置有导致 HAL 崩溃的风险；<br>欺骗让引擎读不到高温即可不限频，系统其余部分完全正常 |
| 电池温度默认**不欺骗** | 电池温控同时承担充电过温保护，关掉风险更高 |
| 不改写 `cooling_device`（默认） | 强制归零会误伤**显示/背光类冷却节点**，直接把屏幕亮度压到最低。<br>欺骗生效时内核本就不会抬升 `cur_state`，归零属于冗余且有害 |
| 皮肤温度用 29.5°C 而非更高 | 注入高于真实的温度会触发厂商「温热降亮度 / 退出高亮」策略 |
| 频率解锁与配置改写**默认开**，OPPO 私有手段**默认关** | 后者与亮度直接相关、作用不明确，需用户按需逐项开启 |
| GPU 节点写入后 `chmod -w` | 阻止用户态守护进程改回（仅 GPU 节点，不用于 `emul_temp`） |
| 未经确认的私有属性一律不写 | 只操作探测到的标准内核节点，不猜厂商私有属性 |

### 亮度异常排查步骤

若出现亮度异常，按顺序逐项排除（**一次只关一项，每改一项观察 10 分钟**）：

```sh
M=/data/adb/modules/realme-gt8-sukisu-thermal-remove
su -c sh $M/action.sh bsafe     # 一键亮度安全预设：还原冷却节点 + 关闭全部风险项
su -c sh $M/action.sh off       # 立即全部退出，等同原厂（用于确认是否本模块导致）
su -c sh $M/action.sh diag      # 诊断：冷却设备（显示类标 ⚠）+ 温感 + 亮度属性
                                #      + 第三方显示配置覆盖（bind mount 判定，直接指出源模块与文件级/目录级）
                                #      + 显示配置内的亮度限制字段（hw_nit_limit 等，v2.8.9）
                                #      + /data/system 运行时副本一致性 + 已知配置核对
su -c sh $M/action.sh rr_restore  # v2.8.7 把 /data/system 显示副本还原成首次快照
su -c sh $M/action.sh touch      # v2.8.8 输入链路优先级体检（InputReader/Dispatcher 的 nice）
```

诊断要点：`UNLOCK_CDEV` 必须为 **0**（为 1 说明在持续把亮度节点往下压）；
标 **⚠显示类(已保护)** 的节点表示模块永不改写。日志：`/data/adb/thermal_remove/thermal_remove.log`

**`diag` 的「第三方显示配置覆盖」段（v2.8.6 引入，v2.8.9 修判据，v2.8.10 补边界）**：会检查
`/my_product/etc/refresh_rate_config.xml`、`oplus_vrr_config.json`、
`display_brightness_config_P_3.xml`、`display_brightness_app_list.xml`
是否被别的模块 bind mount 覆盖，以及 `/vendor/etc/perf/perfboostsconfig.xml` 是否被清空。
这些文件**带面板 ID、来自别的机型/固件版本**，被覆盖是「亮度被钳最低」最常见的外来原因 ——
本模块本身从不写它们，命中就说明是**别的模块**干的（日志会直接打印源模块路径，
并标明是**文件级**还是**目录级** bind mount），去卸载那个模块，调本模块的开关不会有用。

> **v2.8.9 修正**：这一段原来用「文件非空」判定被覆盖，而原厂这些文件本就是非空的
> （`refresh_rate_config.xml` 原厂就有近两千条配置项），导致**每次 diag 必然报 4 个 ⚠**，
> 是 100% 假阳性。现改为查 `/proc/mounts`。
>
> **v2.8.10 补边界**：v2.8.9 只认「挂载点 = 该文件」，而模块 bind 整个 `/my_product/etc`
> 目录时挂载点是**目录** → 漏检。漏检比误报更糟（会让人直接排除掉真正的嫌疑源），
> 现改为「挂载点 = 该文件**或其祖先目录**」，并只认源在 `/data/` 下的挂载 ——
> 否则 `/my_product` 分区挂载本身会被误判成「被覆盖」。输出会标明**文件级 / 目录级**。
>
> **这一段查不出来的东西**（别把「✓ 未发现」当定论）：
> Magisk/KernelSU 的 **magic mount**（挂载类型是 `overlay` 而非 bind）、
> 以及第三方模块对分区文件 **`sed -i` 原地改写**。
> 后者要靠下面的「/data/system 运行时副本」段与 `rr_restore` 去兜。

**`diag` 的「显示配置内的亮度限制字段」段（v2.8.9）**：解析 `oplus_vrr_config.json` 里的
`hw_nit_limit` / `hw_nit_limit_pwm` / `avt_backlight` / `sa_backlight`。

`hw_nit_limit` 是**硬件层 nit 上限**，一旦被第三方写成非 0，就是「亮度怎么拉都上不去」的
直接成因 —— 而我们此前 v2.8.6 的排查只覆盖 sysfs 节点与属性，**完全看不到这一层**。
（这四个字段是在解析「ColorOS 显示优化 2.2」时从它的 VRR 配置里挖出来的。）

> **v2.8.10 修正提取**：v2.8.9 的取值表达式只吃裸数字，遇到字符串 `"0"` 会误报成
> 「未设置」、遇到小数 `0.5` 会被整数截断成 `0` 从而**漏报**真实的亮度钳制。
> 现已兼容三种写法（`0` / `"0"` / `0.5`）。

> **v2.8.11 改判据（实机数据打脸）**：v2.8.10 按「非 0 = 被钳制」报警，拿到真机 diag 后发现
> **GT8 原厂 `hw_nit_limit` 就是 50** —— 也就是说没刷任何模块时它也在报 ⚠，又是一轮假阳性。
> 更糟的是同一份 dumpsys 里 `mMinimumBrightnessCurve = [(0.0,0.0),(2000.0,50.0),(4000.0,90.0)]`
> 也是 50/90 —— 说明这个字段是**亮度曲线百分比**而不是 nits，语义根本不是「上限」，
> 光看绝对值判断不了好坏。
>
> 现改为**与安装期记录的原厂基线比对**，变了才报。基线由 `customize.sh` 首次安装时写入
> `/data/adb/thermal_remove/vrr_baseline.list`（刻意不把 50 写死：固件更新会变）。
> **v2.8.11 之前安装的没有基线，此时只显示数值、不做判定**，重装一次即可建立对照。

### 温感显示修复（v2.8.11）

`action.sh diag` 的「温感 thermal_zone」段从 **v2.8.11 起才有内容**。此前 `dump_temp()` 里
把循环变量 `$_z` 误写成 `$z`，导致 `[ -e "/temp" ]` 恒为假、每个 zone 都 `continue` ——
**整段永远空白**。模块核心功能不受影响（`apply_spoof` 用的是正确的 `$_z`），
但「温感是否在欺骗」这个最关键的判断在诊断输出里看不到。

### 显示配置的「运行时副本」与快照（v2.8.7）

横评第三方模块时发现一件此前被忽略的事：`refresh_rate_config.xml` 这类显示配置，
系统会在 **`/data/system/`** 额外维护一份运行时副本，**优先级高于分区里的原始文件**
（Aurorawk 就是为此专门多改了一份）。我们此前只扫分区，等于漏掉了一半。

本模块**不改写**这两个文件，理由很实在：

| 文件 | 为什么不改 |
|---|---|
| `refresh_rate_config.xml` | `rateId` 语义在不同模块里**互相矛盾**：Aurorawk 把 `2-2-2-2` 改成 `0-0-0-0`，慕容把全部项改成 `3-3-3-3`（锁 120Hz）。同一字段两种相反改法，说明它可能是「温区→降帧映射」也可能是「档位索引」——盲改等于掷骰子，GT8 若是 144Hz 面板，照抄慕容反而是降级 |
| `sys_resolution_switch_config.xml` | 真机未验证结构的分辨率切换表；对方做法是删掉所有 `<switchop package>` 行。我们刚在 v2.8.4 修过「改写产出损坏 XML」的 P0，不为这类文件破例 |

更根本的：本模块靠 `emul_temp` 让系统以为不热，**温度是假的，降帧/降分辨率本就不会触发** ——
改这两个文件是冗余手段，风险却高得多。

所以只做两件低成本但有回旋余地的事：

1. **登记可见化**：安装期扫一遍行业已知的 12 个配置文件名，写入 `patched/known.list`，
   区分 `patched`（本模块改写过）/ `seen`（发现但有意不动）。漏项从此可见，不再静默。
2. **首次快照**：把 `/data/system/` 下的显示类副本备份到
   `/data/adb/thermal_remove/runtime_backup/`。**只在快照不存在时写入**，
   二次安装不会把「已经被改坏的版本」设成新基准。

```sh
su -c sh $M/action.sh diag          # 副本是否与首次快照一致？不一致即被别的东西改过
su -c sh $M/action.sh rr_restore    # 一键还原（只还原本模块快照过的文件）
```

快照**放在模块目录之外**，因此卸载本模块后仍保留 ——「别的模块改坏、又没卸载脚本」
这种事恰恰最可能发生在换模块的时刻。确认不需要就手动 `rm -rf /data/adb/thermal_remove`。

### 输入链路提权（v2.8.8）

`TOUCH_BOOST` 把**厂商触控守护进程**（`vendor-oplus-hardware-touch-V2-service` / `touchDaemon`）
renice 到 -19，但事件分发并不在那两个进程里 —— 它在 **`inputflinger`** 的
`InputReader`（读事件）/ `InputDispatcher`（分发）/ `InputClassifier`（手势判定）线程上。
也就是说厂商服务提权了，交给系统之后的那半程还是默认优先级。

`TOUCH_THREAD_BOOST=1` 补的就是这半程。三个刻意的设计约束：

| 约束 | 原因 |
|---|---|
| 只调 nice，不用 SCHED_FIFO | FIFO 不可抢占。评审过的两个第三方包用 `chrt -f -p 99` 把输入/SF 设成 FIFO，再叠加 `sched_rt_throttle_us=0`（RT 任务唯一的保险丝）—— 任一 RT 线程死循环就是整机硬卡死，只能长按电源 |
| 不碰 `sched_rt_throttle_us` | 同上，那是防死锁的最后一道闸 |
| 记原值、可还原 | 线程的原始 nice 未必是 0，一刀切写回 0 是错的。备份在 `touch_thread.bak`，关开关（5 秒内）/ 切 off / 充电 / 卸载都会按原值还原 |

默认 **关闭**：属于新手段，按本模块惯例先观察。验证方式：

```sh
M=/data/adb/modules/realme-gt8-sukisu-thermal-remove
# 1) 改 mode.conf 的 TOUCH_THREAD_BOOST=1（或 WebUI「进阶选项」里打开），等 5 秒
su -c sh $M/action.sh touch     # 三个线程的 nice 应变成 -19；仍是 0 说明没生效
```

没生效时按顺序查：①开关确实是 1？②当前是不是 `off` / 正在充电（这两种状态会主动还原）？
③`inputflinger` 是不是独立进程（Android 12+ 才是；更老的版本这些线程跑在 `system_server` 内，本开关不适用）。

### 开启进阶项的正确姿势

`REPLACE_ENCRYPTED` 只在重新安装/升级时被读取，运行中改它无效。
出现任何异常（亮度、发热失控、充电变慢、异常重启）立即关回 0。

## 适用环境

- 机型：真我 GT8（**RMX6699**，其他 realme / OPPO 机型可尝试，安装时只提示不阻断）
- 平台：骁龙 8 至尊版（**SM8750**，平台代号 `sun`）
- 系统：**Android 16（SDK 36）/ realme UI 7.0，RMX6699_16.0.0.263（CN01）**，已实机验证
- Root：SukiSU Ultra（KernelSU 系）
- WebUI 无需额外组件：管理器内打开走 `ksu.exec` root 直连；浏览器方式需要支持 `httpd` 的 busybox

### 实机安装结果（2026-10-03，RMX6699_16.0.0.263 CN01）

| 项目 | 结果 |
|---|---|
| `sys_thermal_control_config*.xml` | **该 ROM 上是加密/非明文**，默认跳过替换（REPLACE_ENCRYPTED=0），不做整体替换 |
| `sys_thermal_config.xml` | 命中 **2 处**，已改写 |
| `sys_high_temp_protect*.xml` | 命中 **1 处**，已改写 |
| 扩展集（PATCH_EXTRA） | 默认关闭，未写入 |
| 主手段 | emul_temp 温度欺骗（与内核能力相关，开机后看 WebUI 状态） |

> 即：在 CN01 上，阈值改写只覆盖了部分文件，**去温控主要靠 emul_temp 欺骗**。
> 若欺骗校验长期不通过（日志可见），再考虑逐项开启进阶选项。

---

## 安装

1. SukiSU 管理器 → **模块** → **安装本地模块** → 选择 zip → 重启
2. 或 Recovery 中刷入（需 Recovery 自带 `unzip`）

安装时 `customize.sh` 会扫描以下分区并改写温控配置：
`/odm`、`/my_product`、`/my_stock`、`/my_heytap`、`/my_bigball`、`/my_odm`、`/vendor`、`/product`、`/system`

v2.8.7 起，核对环节**额外扫 `/data/system`**（显示配置的运行时副本，优先级高于分区原文件）。

其中 `my_*` 是 OPPO/realme 私有分区，KernelSU magic mount 不覆盖，与
`/vendor` 等公共分区的改写结果一起写入模块的 `patched/thermal`（核心集）与
`patched/extra`（扩展集）目录，运行时由 `service.sh` 按 `PATCH_THERMAL` /
`PATCH_EXTRA` 开关 bind 挂载生效，随时可开关、出问题立刻卸载。

---

## 工作原理

### 1. 温度欺骗（`emul_temp`）

按温感类型分别设定欺骗目标值：

| 分类 | 匹配规则 | 默认欺骗值 |
|---|---|---|
| SoC / 主板 / 射频 | 其余全部 | 29500（29.5°C） |
| 外壳 / 皮肤 | `*shell*` `*skin*` `*case*` `*frame*` | 33000（33°C） |
| 相机 | `*cam*` `*tof*` `*flash*` | 29500（29.5°C） |
| 电池 / USB | `*batt*` `*battery*` `*usb*` | 29500（**默认不欺骗**） |

电池温度默认**不欺骗** —— 电池温控同时承担充电过温保护，关掉更稳妥。
需要的话在 `spoof.conf` 里把 `SPOOF_BATT=1`；即便开启，dynamic 模式下充电时也会自动停止欺骗。

撤销时写 `0` 到 `emul_temp`，即关闭仿真、恢复真实读数。

### 2. OPPO/realme 私有接口

- `/proc/shell-temp`：写入外壳温度（循环 0–9 索引）
- `/proc/oplus-votable/GAUGE_UPDATE`：默认关闭（`OPPO_GAUGE=0`），作用不明确，不建议开启

### 3. 配置阈值改写（安装时）

| 文件 | 改写内容 |
|---|---|
| `sys_thermal_control_config*.xml` | 开关类置 `false`、等级类置 `-1` |
| `sys_thermal_config.xml` | `isOpen=0`，各阈值抬高 |
| `sys_high_temp_protect*.xml` | 高温保护开关置 `false`，阈值抬到 550–750 |
| `game_thermal_config.xml` | 所有 `clusterN` 置 `-1`（不限频），`fps=60` |
| `QEGA_Config.txt` | `SkinNodeThrottleTemp: 55000` |
| `devices_config.json` | 电池温度区间放宽为 `[100,500]` |
| `charging_*txt` | 温度门槛 +50（即 +5°C） |
| `thermallevel_to_fps.xml` | 所有 `fps="…"` 改写为 `fps="144"` |
| `oppo_display_perf_list.xml` | 只保留系统 / 显示 / OPPO 自身条目，剔除第三方性能限制 |
| `qapegameconfig.txt` | 游戏温度上限 55000、电流上限 2000/1800 |
| `sys_thermal_control_config*.xml`（非明文时） | 用模块内置 `sys_thermal_control_config_default.xml` 整体替换，version 写入当天日期 |

> `sys_thermal_control_config*.xml` 在部分 ROM 上是加密/二进制的，不是合法 XML。
> 这时按行改写没有意义，模块会直接用内置的空策略文件替换（保留 `powersave_mode=1`、
> `safety_thermal_level=12`、`racing_high_temp_safety_level=17` 这几项兜底）。

### 4. 场景化动态模式

`service.sh` 每 5 秒检测一次场景并决定欺骗开关：

```
MODE=off     → 永远不欺骗（等同原厂）
MODE=always  → 永远欺骗
MODE=dynamic → 充电中 → 不欺骗（保护）
               前台在保护名单 → 不欺骗
               前台是游戏且 GAME_PROTECT=1 → 不欺骗
               其余 → 欺骗
```

---

## 配置

编辑模块目录下的文件（`/data/adb/modules/realme-gt8-sukisu-thermal-remove/`），
保存后 **5 秒内自动生效**，无需重启。

### 场景预设档（`presets/`）

WebUI 顶部「场景预设」的每一张卡 = `presets/` 目录下的一个 `.conf` 文件。
五个内置档：

| id | 名称 | 定位 |
|---|---|---|
| `stock` | 原厂 | `MODE=off`，撤销一切，等同未安装 |
| `daily` | 日用均衡 | 场景化去温控 + 不骗电池（保留充电过温保护）+ 满频 |
| `game` | 游戏满血 | 连电池一起欺骗 + GPU 不设上限 + inputflinger 线程提权 |
| `cool` | 降温优先 | CPU 去温控但 GPU 交给原厂（`UNLOCK_GPU=0`），附加手段全关 |
| `debug` | 排障 | **只接管 3 个键**，不动运行模式（局部覆盖的最小示例） |

**自定义一档**：在 `presets/` 下新建 `mystone.conf` 即可，WebUI 会自动出现新卡。

```ini
# PRESET_* 是元数据（卡片展示用），其余行才是要写入的配置键
PRESET_NAME=我的档
PRESET_ICON=🎯
PRESET_ORDER=50          # 排序（小的在前）
PRESET_RISK=safe         # safe=绿边 / caution=橙边
PRESET_TAGS=自用 测试
PRESET_DESC=一句话说明这个场景。
# ── 以下只写你要接管的键，没写的保持用户当前值 ──
MODE=dynamic
SPOOF_BATT=0
```

三条硬性规则（引擎会强制执行）：

1. **局部覆盖**：只接管文件里出现过的键。所以「排障」档能只调日志级别而不动运行模式。
2. **禁止接管 `BLACKLIST`**（以及 `SHOW_REAL_TEMP`、`TOUCH_THREAD_NICE`、
   `REPLACE_ENCRYPTED`）：黑名单与界面偏好属于个性化设置，切档不该清掉它们。
   白名单见 `common/presets.sh` 的 `preset_route_key`。
3. **键与值都要过校验**：键必须在白名单内；`MODE` 只能是 `dynamic|always|off`，
   `LOG_LEVEL` 只能是 `debug|info|warn|error`，其余按 0/1 或数值范围检查，
   非法项**静默丢弃**（宁可少改一项，也不写坏一项）。

命令行等价入口：

```sh
sh /data/adb/modules/realme-gt8-sukisu-thermal-remove/action.sh preset          # 列出全部档与匹配度
sh /data/adb/modules/realme-gt8-sukisu-thermal-remove/action.sh preset game     # 应用某一档
```

> 卡片上的「N/M 项匹配」由**无状态比对**得出：模块不记录"上次点了哪一档"。
> 所以你在 WebUI 里手改任一开关后，界面会立刻如实降为「自定义 — 最接近 X」，不会撒谎。

### `mode.conf`

```ini
MODE=dynamic        # dynamic | always | off
GAME_PROTECT=0      # 游戏时是否保留原厂保护
UNLOCK_FREQ=1       # 解锁 CPU/GPU 频率上限
DISPLAY_PROTECT=1   # 显示/背光类冷却节点永久保护（务必保持 1）
PATCH_THERMAL=1     # 核心温控配置改写（HORAE 成熟规则）
TOUCH_BOOST=1       # 触控服务 renice -19
# ── 以下默认关闭，一次只开一个 ──
UNLOCK_CDEV=0       # 强制归零 cooling_device（⚠ 会压低亮度，默认 0）
STOP_SERVICES=0     # 停用 thermal 服务（兜底）
OPPO_SHELL_TEMP=0   # /proc/shell-temp 写入（⚠ 与亮度直接相关）
OPPO_GAUGE=0        # oplus-votable GAUGE_UPDATE（作用不明）
HORAE_TESTMODE=0    # dumpsys horae testmode
DISABLE_ORMS=0      # 停用 OPPO ORMS 资源/温控管理
PATCH_EXTRA=0       # 扩展配置改写（⚠ 含 oppo_display_perf_list.xml）
SHOW_REAL_TEMP=1    # v2.6 是否允许 WebUI 读取真实温度
REAL_TEMP_DELAY_MS=80 # v2.8.1 真实温度探测第一轮等待（读不到会自动 320/800ms 重试）
CHECK_CONFLICTS=1   # v2.8 模块冲突自检（只告警，不阻断；安装期 + 运行时 + WebUI）
SCAN_RESOURCES=0    # v2.8.6 Tier C「按资源占用扫描」；安装期与 action.sh conflicts 会自动开
REPLACE_ENCRYPTED=0 # 非明文 sys_thermal_control_config 整体替换（仅安装时读取）
RUNTIME_SNAPSHOT=1  # v2.8.7 /data/system 显示配置「首次快照」，改坏时可 rr_restore 还原
CHECK_KNOWN_CFG=1   # v2.8.7 安装期核对 12 个已知配置文件名，结果写入 patched/known.list
TOUCH_THREAD_BOOST=0 # v2.8.8 inputflinger 线程提权（nice，非实时）；默认关，见下方说明
TOUCH_THREAD_NICE=-19 # v2.8.8 上面那项的目标 nice
```

### `spoof.conf`

```ini
SOC_T=29500
SKIN_T=29500        # 外壳/皮肤：29.5°C。设太高会触发厂商降亮度策略，v2.3 起与 SoC 一致
CAM_T=29500
BATT_T=29500
SHELL_PROC_T=29500  # /proc/shell-temp 写入值
SPOOF_BATT=0        # 电池温度是否欺骗
BLACKLIST="*disp* *panel* *lcd* *oled* *amb* *light* *als* *backlight*"
                    # 不参与欺骗的温感（显示/环境光类默认排除，防止亮度异常）
```

### `game_list.conf` / `protect_list.conf`

游戏包名列表、强制保护名单，一行一个包名。

---

## 用法

### WebUI

**首选**：直接在 SukiSU / KernelSU 管理器里点模块的「WebUI」按钮打开。
页面会通过管理器注入的 `ksu.exec` root 桥直接读写配置，**无需启动任何服务器**。

**备选**：浏览器访问 —— 先点模块的 **Action** 按钮（或执行 `action.sh webui`）
启动 loopback 服务，再打开：

```
http://127.0.0.1:37654/
```

此方式需要 busybox `httpd`。面板底部显示当前使用的通道。

面板功能：模式切换、欺骗温度、全部开关（含 v2.3 新增的
`UNLOCK_CDEV` / `DISPLAY_PROTECT` 等）、实时温度（默认只显示关键温感，
可一键显示全部）、日志查看、欺骗校验、亮度异常一键恢复。
v2.8 起状态卡下方会显示**模块冲突检测**结果（无冲突时整块隐藏）。
v2.11.0 起顶部增加**场景预设**卡片区（一卡一档，见「配置 → 场景预设档」），
下方增加**温感树**。

#### 温感树（v2.11.0）

把内核暴露的全部 `thermal_zone`（GT8 上约 83 个）按**功能域**组织成两级树：

```
▾ 🧠 CPU 集群                欺骗 10/10 · 最高 41.2°C      [全组屏蔽]
     cpu-0-2-0      29.5/41.2°C   SoC      [屏蔽]
     cpuss-0-0      29.5/38.9°C   SoC      [屏蔽]
▸ 🔋 电池 / 充电             欺骗 0/5  · 最高 33.1°C      [全组屏蔽]
▾ 📡 射频 / 网络             欺骗 8/9  · 最高 36.4°C      [全组屏蔽]
     nsphvx-0       29.5/36.4°C   SoC      [屏蔽]
     vbat           33.1°C        SoC      [屏蔽]
```

每个叶子行给出四件事：

| 列 | 含义 |
|---|---|
| 数值 | **伪装值** / <span>真实值</span>（真实值只在手动「读取真实温度」后才有） |
| 类别徽章 | 该温感的欺骗类别：`SoC` / `外壳` / `相机` / `电池` —— 决定用哪个 `*_T` |
| 排除原因 | **为什么这个温感没被欺骗**：`已屏蔽`（命中 `BLACKLIST`）/ `电池欺骗已关`（`SPOOF_BATT=0`）/ `内核不支持 emul_temp` |
| 屏蔽按钮 | 一键把该温感（或整个分类）加入/移出 `BLACKLIST` |

两点设计说明：

- **分类映射在后端算**（`get_temps` 输出 `grp/cls/tgt/ex` 四个字段），
  前端只做分组展示。名称→类别这类规则若前后端各写一套迟早走偏，
  回归套件里有一条「拿 16 个真机温感名把 `cls→目标温度` 与
  `functions.sh` 的 `zone_target_into` 逐条对拍」的断言守着。
- **懒加载**：树默认不请求，点「加载温感树」才拉全量（83 个温感）；
  页面不可见时不做任何刷新，与模块整体的省电取向一致。

### 命令行

```sh
M=/data/adb/modules/realme-gt8-sukisu-thermal-remove
su -c sh $M/action.sh status     # 查看状态与环境
su -c sh $M/action.sh temp       # 查看当前温度
su -c sh $M/action.sh on         # MODE=always
su -c sh $M/action.sh dynamic    # MODE=dynamic
su -c sh $M/action.sh off        # MODE=off
su -c sh $M/action.sh conflicts  # v2.8 检测其他温控模块（只报告，不改任何东西）
su -c sh $M/action.sh diag       # 亮度/温控诊断（冷却设备 + 温感 + 亮度属性）
su -c sh $M/action.sh preset     # v2.11 列出全部场景预设档 + 当前匹配度
su -c sh $M/action.sh preset game  # v2.11 应用某一档（只接管该档声明过的键）
su -c sh $M/action.sh fuse       # v2.12 温度保险丝状态与触发记录
su -c sh $M/action.sh panic      # v2.12 进入安全模式：撤销一切改写 + MODE=off（自救）
su -c sh $M/action.sh doctor     # v2.13 一键体检：环境/生效/风险，8 节报告（可直接复制反馈）
su -c sh $M/thermal_spoof.sh show   # 打印各温感（标出欺骗中的）
```

---

## 模块冲突自检（v2.8）

**为什么需要**：温控模块之间会互相覆盖。同一个 `emul_temp`、同一个 horae 服务、
同一份 `sys_thermal_config.xml`，两个模块都在写时**没有仲裁者**，谁最后执行谁说了算。

| 已确认会冲突的模块 | 冲突点 |
|---|---|
| `thermal_horae_extreme`（温控 Horae 统一控制） | 争抢 `sys_thermal*`/`game_thermal` XML 与 horae 服务（`ctl.start/stop` 与本机策略互斥） |
| `extreme_gt`（Extreme GT） | 争抢同一批 XML；且其 `emul_temp` 欺骗在 SM8750 上根本不执行 |
| `manyapps_moka`（Moka） | 8 层混淆 + `eval`，`init.svc.horae=stopped` 与本机直接对撞，行为不可审计 |
| `murongltpo`（慕容 ColorOS 附加模块，v2.8.6 登记） | 不碰温控资源（故只标 **medium**）：清空 `perfboostsconfig.xml` 关掉高通 perf boost、并全局锁 120Hz，与本模块 `UNLOCK_FREQ`/`TOUCH_BOOST` 目标相反；其显示配置来自 2024 年固件与其它机型，可能引发亮度/刷新率异常 |
| `ColorOS_Display_Optimization`（ColorOS 显示优化，v2.8.9 登记） | 同样只标 **medium**：整份替换 `/my_product/etc/oplus_vrr_config.json`（`version 20240910`，`sf_framerate_ranges` 上限只有 **120**，而 GT8 是 **144Hz** 面板 → 覆盖即降级）；`sa_backlight` 全亮度调光与官方「全程 DC」重复且档位无 144。**与上一行覆盖同一个文件，两者互斥** |

三条查看途径：

```sh
# 1) 安装期：刷机日志里会直接列出命中的模块（不阻断安装）
# 2) 运行时：
su -c sh $M/action.sh conflicts
# 3) WebUI：状态卡下方（有冲突才显示，无冲突整块隐藏）
```

**装多个温控模块不会叠加效果，只会互相覆盖。建议只保留一个。**
若确实要对比测试，请先卸载 / 禁用另一个再重启，并在这台的日志里确认只有一方在写。

开关：`mode.conf` → `CHECK_CONFLICTS=0` 可完全关闭检测（不推荐）。

### Tier C：按「资源占用」扫描（v2.8.6）

上面两层都**只看身份**（id / 名称关键词），遇到没见过的模块就完全静默 ——
而「亮度异常」「参数莫名失效」恰恰常来自身份不相关、却往同一批资源上写的模块。
Tier C 补上第三种判据：**翻开第三方模块的 `*.sh` / `*.prop` / `*.rc`，
查里面有没有出现 `emul_temp`、`thermal_zone`、`cooling_device`、`horae`、
`sys_thermal`、`scaling_max_freq` 等资源关键字**，命中报 `low` 级「疑似」。

```sh
# 手动排查时临时开启（不管 mode.conf 里是 0 还是 1）：
sed -i 's/^SCAN_RESOURCES=.*/SCAN_RESOURCES=1/' $M/mode.conf
su -c sh $M/action.sh conflicts
```

| 项 | 说明 |
|---|---|
| 默认状态 | **关闭**（`SCAN_RESOURCES=0`）。安装期与 `action.sh conflicts` 会自动强制开启 |
| 为什么不常开 | 要读第三方模块的文件；运行时主循环 5 秒一轮会放大 IO。**主循环永远不开** |
| 误报处理 | 注释里提到关键字也会命中，故一律报 `low`「疑似」；本库只告警，绝不改动他人文件 |
| 扫描范围 | 仅 `*.sh`/`*.prop`/`*.rc`，单文件命中即停、限 512 KB，不做全量递归 |

---

## 自检

```sh
su -c cat /data/adb/thermal_remove/thermal_remove.log
```

关键日志行：

| 日志 | 含义 |
|---|---|
| `欺骗已应用：N 个温感` | 欺骗生效，N 为成功写入的温感数 |
| `欺骗已应用：N 个温感，M 个不支持 emul_temp` | 部分温感无 `emul_temp`，属正常 |
| `✓ 欺骗校验通过（记账 N 个温感）` | 开机 60 秒后自检通过，N 个温感已应用欺骗（v2.8.5 起以记账为准） |
| `! 欺骗校验未通过（记账为空），补一次应用` | 自检失败，已自动补一次；随后输出诊断明细 |
| `校验详情: horae 读到 […]` | 诊断信息：horae 实际读数（仅供参考，不作判据） |
| `提示: OPPO_SHELL_TEMP=0 …` | `/proc/shell-temp` 未写入，该路径不参与校验 |
| `! 未发现 emul_temp 节点，回退激进模式` | 内核不支持仿真，已切到停服务 + 解频 |
| `→ 温控已移除 (mode=xxx)` / `→ 温控已恢复` | 状态切换 |
| `mount: /xxx` | 私有分区（my_*）配置已 bind 挂载 |
| `✓ 冲突自检：未检测到其他温控模块` | 正常 |
| `⚠ 冲突模块[high]: xxx` | **检测到其他温控模块**，会争抢同一批资源，建议只保留一个 |

---

## 卸载

管理器中卸载 → `uninstall.sh` 撤销欺骗、还原 sysfs、停掉 WebUI 与主循环、清理数据目录。

---

## 救砖

| 情况 | 处理 |
|---|---|
| 卡开机 / 无限重启 | 进 Recovery 删除 `/data/adb/modules/realme-gt8-sukisu-thermal-remove` |
| 无法进系统 | fastboot 刷回备份的 `boot` / `init_boot` |
| 临时禁用全部模块 | KernelSU / SukiSU 开机阶段连按音量减进入安全模式（视版本而定） |

---

## 目录结构

```
/data/adb/modules/realme-gt8-sukisu-thermal-remove/
├── module.prop
├── customize.sh          安装时扫描 + 改写厂商配置（输出到 patched/）
├── post-fs-data.sh       早期温度欺骗（挂载统一放 service.sh）
├── service.sh            主守护：场景检测 + 欺骗/撤销 + 配置挂载
├── boot-completed.sh     开机完成后补一次
├── action.sh             Action 按钮 / 命令行入口
├── uninstall.sh
├── thermal_spoof.sh      独立欺骗脚本
├── webui_server.sh       按需启动 loopback WebUI（busybox httpd）
├── common/functions.sh   公共函数库
├── common/conflicts.sh   v2.8 模块冲突检测库（零副作用，安装期与运行时共用；v2.8.6 增 Tier C 资源扫描）
├── common/presets.sh     v2.11.0 场景预设档引擎（零副作用，纯函数；api.sh 与 action.sh 共用）
├── presets/              v2.11.0 场景预设档案，一个 .conf 一档
│   ├── stock.conf  daily.conf  game.conf  cool.conf  debug.conf
│   └── （自己放一个 *.conf 就会在 WebUI 里多出一张卡）
├── mode.conf  spoof.conf  game_list.conf  protect_list.conf
├── sys_thermal_control_config_default.xml   非明文 XML 的替换模板
├── patched/              安装时生成的配置改写（thermal=核心集 / extra=扩展集）
│   └── known.list       v2.8.7 已知配置核对：patched|路径 / seen|路径 / snapshot|…
└── webroot/              WebUI（index.html / style.css / cgi-bin/api.sh）

/data/adb/thermal_remove/
├── thermal_remove.log
├── sysfs.bak             sysfs 原始值备份
├── prop.bak              属性原始值备份（ORMS）
├── spoof.list            欺骗记账：dir|value（判定「欺骗中」的唯一依据）
├── mounts.list           已 bind 挂载的配置路径
├── touch_thread.bak      v2.8.8 输入线程原 nice 备份：tid|原值（关开关/卸载时据此精确还原）
├── state                 on / off
└── runtime_backup/       v2.8.7 /data/system 显示配置的首次快照（卸载本模块后保留）
```

---

## 已知局限

1. **硬件级过热保护移除不了** —— 骁龙 8 至尊版的硅片结温保护由硬件实现。
2. 温度欺骗依赖内核开启 `CONFIG_THERMAL_EMULATION`（即有 `emul_temp` 节点）。不支持时会自动回退。
3. `emul_temp` 只影响 kernel thermal core；若厂商守护进程走私有通道读温，欺骗对它无效，此时需要开 `STOP_SERVICES=1`。
4. 配置改写规则基于 OPPO/realme 常见文件命名。若你的 ROM 用了别的路径，安装日志里会显示 `· xxx × 0`，需要针对性补充规则。
