# GT8 ThermalRemove v2.17.4

针对 **真我 GT8（RMX6699 / 骁龙 8 至尊版 SM8750，平台代号 sun）** 的 SukiSU（KernelSU）温控模块。
适配 **Android 16 / realme UI 7.0（RMX6699_16.0.0.263 CN01）**，已在实机安装验证。

> 平台说明：早期版本按传闻写作 SM8850；**实机安装日志显示 `ro.board.platform=sun / ro.soc.model=SM8750`**，
> 即骁龙 8 至尊版（第一代至尊版的 SM8750），已按实测更正。

> **快速开始**：安装 → 打开 WebUI 切「游戏满血」档即可。风险务必先读下方「风险警告」。

## 文档导航

| 想做什么 | 看哪里 |
|---|---|
| 快速上手 + 风险 + 安装 + 用法 | 本文件 |
| 每个配置键、目录结构 | [docs/配置参考.md](docs/配置参考.md) |
| 亮度异常 / 冲突 / 自检等排障 | [docs/排障.md](docs/排障.md) |
| 设计取舍 + 工作原理 + 版本演进史 | [docs/原理与取舍.md](docs/原理与取舍.md) |

> v2.17.3 起把原 600+ 行单 README 拆成上面四份（U4 文档分层），本文件只保留
> 「快速开始 + 风险 + 用法 + 卸载/救砖 + 已知局限」，其余内容按主题归入 `docs/`。
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

## 已知局限

1. **硬件级过热保护移除不了** —— 骁龙 8 至尊版的硅片结温保护由硬件实现。
2. 温度欺骗依赖内核开启 `CONFIG_THERMAL_EMULATION`（即有 `emul_temp` 节点）。不支持时会自动回退。
3. `emul_temp` 只影响 kernel thermal core；若厂商守护进程走私有通道读温，欺骗对它无效，此时需要开 `STOP_SERVICES=1`。
4. 配置改写规则基于 OPPO/realme 常见文件命名。若你的 ROM 用了别的路径，安装日志里会显示 `· xxx × 0`，需要针对性补充规则。
