# 模块解析：ColorOS 显示优化 2.2

> 包：`ColorOS显示优化2.2.zip`　7 534 B / 13 项
> `id=ColorOS_Display_Optimization`　`v2.2` / `versionCode=22`　`author=XmikN`
> description：*全亮度8T-LTPO增强，在不降低流畅度的情况下最大程度降低功耗*

---

## 一、整体作用与执行流程

**它是个"单文件配置替换包"，不是功能模块。** 13 项里 12 项是骨架，真正的内容只有一个 JSON。

```
安装（标准 Magisk update-binary，未魔改）
  └─ 把 my_product/etc/oplus_vrr_config.json 解到模块目录
每次开机（post-fs-data.sh，全文 2 行）
  └─ mount --bind $MODDIR/my_product/etc/oplus_vrr_config.json
                 /my_product/etc/oplus_vrr_config.json
```

| 文件 | 大小 | 实际作用 |
|---|---|---|
| `my_product/etc/oplus_vrr_config.json` | 30 606 B | **唯一实质内容**：OPPO/realme 的 VRR（可变刷新率）总配置 |
| `post-fs-data.sh` | 111 B | 一行 bind mount |
| `service.sh` | 14 B | 只有 `MODDIR=${0%/*}`，**完全空转** |
| `system.prop` | **0 B** | 空文件，无意义 |
| `module.prop` | 193 B | 元数据 |
| `update-binary` | 3 999 B | 原版 Magisk 安装器（`$MAGISK_VER_CODE -ge 20400 → install_module`），无自定义逻辑 |
| `updater-script` | 8 B | `#MAGISK` |

**架构上有一处是对的**：配置放在 `my_product/etc/` 而**不是** `system/my_product/etc/`。`/my_product` 是 OPPO 私有分区，不在 Magisk magic mount / KernelSU overlay 的支持列表里 —— 走 overlay 不会生效，只能靠 bind mount。这个选择正确。

代价是：**生效完全依赖那一次 mount**，卸载或禁用后必须重启才恢复，且没有 `uninstall.sh` 做任何收尾。

---

## 二、核心数据结构：`oplus_vrr_config.json`

顶层**不是对象而是长度为 20 的数组**，每个元素是一个功能段（`[{k:v},{k:v},…]` 的段落式布局）。这种结构对"整份替换"极不友好：缺一段就是缺一段，服务端若按下标或按段名读取，行为不可预测。

| # | 段 | 值 | 说明 |
|---|---|---|---|
| 0 | `filter_name` | `oplus_adfr_config` | 配置名（ADFR = Adaptive Dynamic Frame Rate） |
| 1–2 | `version` / `sub_version` | **20240910** | 配置版本戳 |
| 3 | `feature_sa` | `"true"`（**字符串**） | SA 背光总开关 |
| 4 | `feature_osync:3`, `frame_stablize:true` | | osync 帧同步 |
| 5 | `feature_hybrid_acc` | true | 混合加速 |
| 6 | `sa_backlight:true` + `sa_backlight_strategy` | fps **120/90/60** × `["1:1","3000:1"]` | 全亮度 SA 背光策略（即 description 说的 8T-LTPO 增强） |
| 7 | `sa_backlight_single_pulse` | 同上 | 单脉冲调光版本 |
| 8 | `game_list` | 23 条 / 31 个包名，7 条带 `kfc` | 游戏背光与帧率策略，`kfc_target/jitter=[60,120]` |
| 9 | ADFR 主段（15 键） | 见下 | 降帧策略核心 |
| 10–11 | `cvt:true` / `frtc:false` | | 帧率转换 / FRTC |
| 12 | `avt:false`, `avt_backlight:85`, `avt_min_fps:60`, `avt_modes:[120]` | | 整体关闭 |
| 13 | **帧率档位表** | 见下 | 最关键 |
| 14 | `deferred_mode_change` | false | |
| 15 | `touch_frame_change:true`, `strategy:2`, `frtc_capability:360`, whitelist **191** 条, blacklist 空, `min_framerate_map` 空 | | 触控切帧 |
| 16–17 | `normalized_minfps:true` / `limit_fps_when_app_exit:true` | | |
| 18 | `debug_overlay` | 15 个数值 | 调试浮层 |
| 19 | `record_reduce_rate_config` | wifi/投屏/录屏各一个降帧系数 | |

### [13] 帧率档位表（决定性证据）

```json
"sf_framerate_ranges":  ["120","100","90","72","60","50","25","24","30","10","1"]
"frtc_framerate_ranges":["120","100","90","72","60","50","25","24","30","10","1"]
"panel_idle_time": 10, "sf_idle_time": 100, "max_mixerlayernum": 11
"partial_refresh_ratios": ["5","10","20","30","50","70","90","99","100"]
```

### [9] ADFR 主段要点

```
touch_idle:false   hw_enable:true   sw_enable:true   adfr_enable:true
timeout:2500ms     content_threshold:10   content_gap_ms:800
hw_nit_limit:0     hw_nit_limit_pwm:0            ← 硬件亮度限制阈值
sw_whitelist_3rd: 抖音/快手/快手极速版 → [30]     ← 第三方强制 30fps
adfr_to_hw: B站/芒果/头条视频/腾讯视频/爱奇艺/微博
special_timeout: 微信3500 联系人3500 相册4000 桌面5000 …
blacklist: 112 条（几乎全是游戏 + 设置/短信/工程模式/安兔兔/鲁大师）
sw_negligible_overlay: StatusBar/NavigationBar/游戏浮标 等 17 个图层不计入内容判定
```

---

## 三、与真我 GT8 的适配性判定（P0：不适用）

已核实 GT8 官方规格（realme 官网 / 中关村在线 / Notebookcheck 一致）：
**6.79" LTPO AMOLED，最高 144Hz，瞬时触控采样率 3200Hz，官方标注"全程 DC"，realme UI 7.0 / Android 16。**

**这份配置与 GT8 至少有三处硬冲突：**

| 项 | 配置值 | GT8 实际 | 后果 |
|---|---|---|---|
| `sf_framerate_ranges` 上限 | **120** | **144** | 全文件正则扫描确认 **144 一次都没出现**；所有 fps 档位只到 120（`sa_backlight_strategy` 的 120/90/60、`kfc_target[60,120]`、`avt_modes[120]`）。覆盖后 144Hz 档位消失 → **实为降级** |
| `version` | **20240910**（2024-09） | 2025-10 上市 | 配置早 13 个月且来自别的机型（档位组合 `120/100/90/72/60/50/25/24/30/10/1` 是典型 2K 120Hz 三星 LTPO 屏） |
| `sa_backlight` 全亮度调光增强 | true | 官方已"全程 DC" | 重复且可能打架；策略只有 120/90/60 三档，**144Hz 下无匹配档位** |
| `frtc_capability` | 360 | 瞬时采样 3200Hz | 字段语义不明，量级差 9 倍，来源机型明显不同 |

**最可能的实际结果**：`oplus_vrr_config.json` 的消费方（Oplus VRR/ADFR 服务）在版本或字段不匹配时**直接拒绝加载、回退硬编码默认** —— 这种"看起来装了其实完全没生效"反而是最幸运的情况。反之若被接受，就是 144Hz → 120Hz。

---

## 四、问题清单（按严重度）

### P0

1. **整份替换 30 KB 跨机型跨版本配置**（`post-fs-data.sh:3`）—— 20 段里 `[15].min_framerate_map` 是空字典、`[15].blacklist` 是空数组，说明来源机型本就不支持这些能力；GT8 需要的字段（144 档位、3200Hz 采样相关）一个都没有。缺字段的后果取决于服务端实现，可能是降级、可能是崩溃重启。
2. **`version: 20240910` 与 GT8 不匹配**（`[1]`）—— 同上，是 P0-1 的直接证据。

### P1

3. **`mount --bind` 无任何返回值检查**（`post-fs-data.sh:3`）—— 目标不存在、分区未挂载、被 SELinux 拒绝，三种情况都会让 mount 失败，而模块在管理器里仍显示"已安装已激活"，**静默无效**。加一句 `[ -f 目标 ] && mount … || echo 错误` 成本极低。
4. **无 `uninstall.sh`** —— bind mount 不持久化，重启即恢复，所以实际影响有限；但没有任何地方能确认"到底 mount 成功没有"，排查时只能靠 `mount` 命令。
5. **`$MODDIR` 未加引号** —— 路径不含空格所以不出事，属规范问题。

### P2

6. **`system.prop` 是 0 字节** —— Magisk 的 `$PROPFILE` 检测会把它复制进模块目录，加载空 propfile 无意义。应删除该文件。
7. **`service.sh` 只有一行 `MODDIR=${0%/*}`** —— 完全空转，Magisk 仍会执行一次 late_start service。应删除。
8. **`[9].blacklist` 有 2 个重复包名** —— `com.tencent.tmgp.eyou.blqx`、`com.tencent.tmgp.kaopu.jzpaj` 各出现 2 次（112 条里）。无害，但说明没有任何校验。
9. **`[3].feature_sa` 是字符串 `"true"` 而非布尔 `true`** —— 与 `[4].frame_stablize:true` 的布尔写法不一致。若服务端按布尔解析，字符串会被判为 false 或抛异常。要么原版就是如此（跨版本遗留），要么是手改失误。
10. **文件无结尾换行**（`endswith('\n') == False`）—— 部分解析器对无尾换行宽容，但不够规范。

---

## 五、对本项目的价值

### 可复用（2 项，均低成本）

**★1 亮度嫌疑源扩展：VRR 配置里藏着亮度字段**
这是本次最有价值的发现。本模块 v2.8.6 起的 `action.sh diag` 亮度排查只覆盖 **sysfs 节点 + 属性**，`oplus_vrr_config.json` 只检查了"文件在不在"。而这份配置里实际有 4 个亮度相关字段：

```
[9]  hw_nit_limit: 0        hw_nit_limit_pwm: 0
[12] avt_backlight: 85      avt_modes:[120]
[6]  sa_backlight:true      sa_backlight_strategy[].list=["1:1","3000:1"]
```

其中 `hw_nit_limit` 是**硬件层 nit 上限** —— 一旦被第三方写成非 0，就是"亮度怎么拉都上不去"的直接成因，且完全不在我们目前的排查面上。建议在 `diag` 的亮度段加一步：读取这些字段并标注非 0 值。

**★2 冲突库登记 `ColorOS_Display_Optimization`**
不碰温控资源，所以**不是 high**；但它是"整份替换显示配置 + 潜在锁 120Hz"，与本模块目标相反，且与**慕容包覆盖同一个文件**（两者都有 `my_product/etc/oplus_vrr_config.json`，谁后 mount 谁生效，互斥）。建议登记为 **medium**，与已登记的 `murongltpo` 同级。

### 不可复用

`game_list` 的 kfc 帧率控制、191 条 `touch_frame_change` 白名单、`debug_overlay`、`record_reduce_rate_config` —— 全部是显示域策略，与温控主线正交，且来源机型不符。

### 记一条打包规范（反面教材）

`system.prop` 0 字节、`service.sh` 空转 —— 两个文件都被打包且都会被执行/加载，纯冗余。我们自己打包时应保证：**空文件不进包**。

---

## 六、附带发现：本模块 `action.sh diag` 存在假阳性（自测发现）

核对集成点时发现的**我们自己的 bug**（v2.8.6 引入，v2.8.7/2.8.8 仍在）：

```sh
# action.sh，约 :85
for _f in /my_product/etc/refresh_rate_config.xml \
          /my_product/etc/oplus_vrr_config.json \
          /my_product/vendor/etc/display_brightness_config_P_3.xml \
          /my_product/vendor/etc/display_brightness_app_list.xml; do
    if [ -s "$_f" ]; then
        echo "  ⚠ $_f 被覆盖（N B）"   # ← 判定条件错了
```

`[ -s ]` 只表示"文件大小 > 0"，而**原厂这些文件本来就是非空的**（`refresh_rate_config.xml` 原厂就有近两千条配置项）。所以这一步**每次 diag 都会报 4 个 ⚠**，即便一个第三方模块都没装 —— 100% 假阳性。

**正确判据**：查挂载表，只有 bind mount 才会造成覆盖。

```sh
# /proc/mounts 里出现该路径 = 被某个模块 bind mount 了
grep -q " $_f " /proc/mounts 2>/dev/null && echo "  ⚠ $_f 被 bind mount 覆盖"
```

同一循环里对空 `perfboostsconfig.xml` 的判定（`[ -e ] && [ ! -s ]`）是**正确的**，因为"存在但为空"确实是异常 —— 只有那 4 个文件的判据写错了。

---

## 七、结论清单

| # | 结论 | 依据 |
|---|---|---|
| 1 | **不建议在 GT8 上使用** | `sf_framerate_ranges` 上限 120，全文件无 144；GT8 是 144Hz LTPO |
| 2 | 配置版本 `20240910`，来源机型为 2K 120Hz 屏 | 档位组合 + 空 `min_framerate_map` / 空 blacklist |
| 3 | 与慕容包**互斥**（同覆盖 `my_product/etc/oplus_vrr_config.json`） | 两包文件清单对比 |
| 4 | 生效完全依赖一次无检查的 bind mount，失败即静默无效 | `post-fs-data.sh:3` |
| 5 | ★ 值得提取：`hw_nit_limit` 等 4 个亮度字段 → 补进 `diag` | 本模块亮度排查目前只查 sysfs/属性 |
| 6 | ★ 值得登记：id → `conflicts.sh` medium | 不碰温控但锁 120Hz，与慕容同目标文件 |
| 7 | 记规范：空 `system.prop` / 空转 `service.sh` 不应进包 | 本包 P2-6 / P2-7 |
| 8 | ⚠ 本模块 `diag` 第三方覆盖判定假阳性，需改用 `/proc/mounts` | `action.sh` 约 :85 |

---

## 八、落地情况（v2.8.9 已实施）

第 5、6、8 三项已落实，模块升至 **v2.8.9 / versionCode 40**。

| 项 | 落地位置 | 实现要点 |
|---|---|---|
| ★1 亮度字段 | `action.sh diag` 新增「显示配置内的亮度限制字段」段 | 用 `sed` 逐键提取 `hw_nit_limit` / `hw_nit_limit_pwm` / `avt_backlight` / `sa_backlight`；**非 0 才报警**。不依赖 `jq`（设备通常没有），紧凑单行 JSON 也能提取（已测） |
| ★2 冲突登记 | `common/conflicts.sh` `match_known` | `ColorOS_Display_Optimization` → medium；另加名称兜底 `*显示优化*)` 应对二改包改 id |
| 假阳性修复 | `action.sh diag` 第三方覆盖段 | 判据从 `[ -s ]`（文件非空）改为 `awk '$2==m' /proc/mounts`（bind mount），并**打印源模块路径**直接指认；`$2` 字段精确比较，不用 grep（路径里的 `.` 会被当正则） |

**实机验证方式**：

```sh
M=/data/adb/modules/realme-gt8-sukisu-thermal-remove
su -c sh $M/action.sh diag
# 期望：
#   1) 未刷任何显示模块时 → 「✓ 未发现第三方显示配置覆盖」（旧版必报 4 个 ⚠）
#   2) 「显示配置内的亮度限制字段」段打印 4 个值，hw_nit_limit 应为 0（原厂）

su -c sh $M/action.sh conflicts
# 刷了本包时应列出：疑似: ColorOS 显示优化 (v2.2)

# 确认 GT8 的 VRR 配置版本（判断是否真的被降级）：
su -c 'sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p" /my_product/etc/oplus_vrr_config.json | head -1'
# 原厂应为 2025xxxx；若显示 20240910 说明确被覆盖 → 卸载该模块并重启
```
