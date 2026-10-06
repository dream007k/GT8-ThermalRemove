# 模块评审：慕容 ColorOS 附加模块 1.1（murongltpo）

- 评审对象：`慕容ColorOS附加模块1.1.zip`（182 KB / 19 个文件）
- 评审目的：评估其中哪些部分值得复用、是否应整合进 `RealmeGT8-SukiSU-ThermalRemove` v2.8.5（真我GT8 优化模块）
- 目标机型：真我 GT8（RMX6699 / SM8750 / Android 16 / realme UI 7.0）
- 评审日期：2026-10-04

---

## 0. 一句话结论

**不建议整体并入，也不建议直接刷入目标机。** 该模块是一个"显示/刷新率/特性解锁"向的 ColorOS 通用包，与本项目"温控移除 + 性能保持"的主线基本正交；其主体资产（5 个整机厂商配置文件、40+ 条渲染属性）**强机型耦合且来自 2024 年固件/其它平台**，直接用在 GT8 上风险远大于收益。

真正值得借鉴的只有 **3 处**，其中只有 1 处涉及代码改动：

| # | 内容 | 结论 | 体量 |
|---|------|------|------|
| ★1 | 冲突检测从"按 id/名称"扩展到"按资源占用扫描" | **建议引入**（改造后） | 约 25 行，新增到 `common/conflicts.sh` |
| ★2 | `DragMinSwitchSpeed` / `QuietInterval` 触控手势参数 | **条件引入**（先实机验证） | 2 行，追加到 `system.prop` |
| ★3 | 亮度嫌疑属性清单 + 已知模块名单 | **建议引入** | diag 增补 6 行 + `match_known` 增补 5 行 |

其余全部建议**保持独立 / 不引入**，理由见第 2 节。

---

## 1. 模块画像

### 1.1 结构

| 文件 | 体积 | 作用 | 平台归属 |
|------|------|------|---------|
| `module.prop` | 293 B | id=`murongltpo`，v1.1 | — |
| `META-INF/.../update-binary` | 4.0 KB | **Magisk 标准安装器**（182 行，含 19.0+ 版本检测） | Magisk |
| `customize.sh` | 2.9 KB | 唯一逻辑：`check_conflict_modules`（音量键交互） | Magisk |
| `post-fs-data.sh` | 1.4 KB | 9 条裸 `mount --bind`，**全文件替换** | — |
| `system.prop` | 4.5 KB | 130 行 / 101 个键（含 3 个重复键、17 个置空键） | — |
| `my_product/etc/refresh_rate_config.xml` | 189 KB | 2053 条 App 刷新率策略，`defaultRateId="3-3-3-3"` | ColorOS 通用 |
| `my_product/etc/oplus_vrr_config.json` | 20 KB | ADFR / osync / SA 背光 / 游戏列表 | ColorOS 通用 |
| `my_product/vendor/etc/display_brightness_config_P_3.xml` | 605 KB | 亮度→nit 查找表（`max="10239"`） | **面板强耦合** |
| `my_product/vendor/etc/display_brightness_app_list.xml` | 32 KB | 应用降亮度名单 | ColorOS 通用 |
| `my_product/vendor/etc/multimedia_display_feature_config.xml` | 27 KB | 多媒体显示特性 | ColorOS 通用 |
| `my_product/vendor/etc/multimedia_pixelworks_game_apps.xml` | 20 KB | Pixelworks 独显游戏名单 | **需独显硬件** |
| `my_product/vendor/etc/multimedia_display_trackpoint_config.xml` | 1.4 KB | logcapture / trackpoint 埋点 | ColorOS 通用 |
| `system/vendor/etc/perf/perfboostsconfig.xml` | **0 B** | **清空**高通 perf boost 配置 | 骁龙 QTI |
| `system/vendor/etc/perf/perfconfigstore.xml` | **0 B** | **清空**高通 perf 配置存储 | 骁龙 QTI |
| `system/vendor/etc/powercontable.xml` | 1.6 KB | 全是 `/proc/perfmgr/*`、`ged` 路径 | **天玑 MTK** |
| `system/vendor/etc/powerscntbl.xml` | 62 B | 空 `<SCNTABLE>` | **天玑 MTK** |
| `system/vendor/etc/power_app_cfg.xml` | 329 B | 空 `<WHITELIST>` | **天玑 MTK** |

### 1.2 平台判定

| 证据 | 结论 |
|------|------|
| `powercontable.xml` 内 5 条 CMD 全部指向 `/proc/perfmgr/tchbst/user/usrtch`、`/sys/kernel/ged/*` | MTK perfmgr + GPU ged，**天玑平台** |
| `perfboostsconfig.xml` / `perfconfigstore.xml`（QTI perf）被清空 | 作者同时照顾骁龙，但用的是"关掉"而非"配置" |
| `refresh_rate_config.xml` version=`20240923`、`oplus_vrr_config.json` version=`20240923` | 2024 年 9 月固件，非 GT8（realme UI 7.0 / A16）同期 |
| 文件头注释 `mode_auto-mode_93-mode_63-mode_122-mode_144`（**5 个模式**），但全文件 rateId 均为 **4 段** `3-3-3-3` | 头尾版本不一致，说明文件是跨版本拼接的 |
| `display_brightness_config_P_3.xml` 文件名含面板 ID `P_3` | **面板绑定**，跨机型替换等于换掉背光曲线 |

> 结论：**这是一份跨机型拼装包，不是为 GT8 设计的。** 它对 GT8 的价值只能逐条剥离评估。

---

## 2. 逐项评估：不建议引入的部分

| # | 内容 | 为什么不引入 | 若强用的副作用 |
|---|------|--------------|----------------|
| A | `refresh_rate_config.xml`（全局锁 120Hz） | 1983/2053 条被改成 `rateId="3-3-3-3"`（=auto/90/60/120 四档全部锁 120Hz）。GT8 若面板支持 144Hz，这反而是**降级**；且会整体覆盖 GT8 自己的新版策略（2025 年新增 App 条目全部丢失） | 刷新率异常、高刷失效、功耗上升、与 `debug.sf.frame_rate_multiple_threshold=200`（本模块已设）语义打架 |
| B | `display_brightness_config_P_3.xml` | 605 KB 亮度→nit 查找表，文件名带面板 ID。GT8 面板不同 | **亮度曲线错乱**：最轻是调光不线性，重则亮度被钳在最低/最高——正好撞本模块历史上最难排查的 `bsafe` 故障面 |
| C | `oplus_vrr_config.json` + `multimedia_*`（4 个） | ADFR / osync / Pixelworks 依赖具体显示链路；`multimedia_pixelworks_game_apps.xml` 需要 Pixelworks 独显，GT8 未必有 | 触发上层初始化不存在的硬件；SA 背光策略（`sa_backlight` fps=120）可能与 A 段叠加导致背光抖动 |
| D | 空 `perfboostsconfig.xml` / `perfconfigstore.xml`（0 B） | 这是"**关闭**高通 perf boost"的技巧，与本模块 `UNLOCK_FREQ=1` / `TOUCH_BOOST=1` 的提性能目标**方向相反** | QTI perf 服务读到空 XML 可能回退默认或直接失效；app 启动/触控 boost 消失，本模块的触控提速被部分抵消 |
| E | `powercontable.xml` / `powerscntbl.xml` / `power_app_cfg.xml` | 全是 MTK perfmgr 路径，SM8750 上**完全无效** | 纯噪声；`power_app_cfg.xml` 清空白名单在 MTK 上会禁掉所有 perf 提频 |
| F | 40+ 条 `debug.sf.*` / `vendor.display.*` / `ro.surface_flinger.*` | 强机型+版本耦合的渲染调参。例如 `debug.sf.early.sf.duration=11500000`（11.5 ms）已**大于 120Hz 帧周期 8.33 ms、144Hz 帧周期 6.94 ms**，语义可疑；`debug.sf.latch_unsignaled=1` 不等 fence 直接 latch | 撕裂/花屏/掉帧；`enable_layer_caching=0` 增加功耗（与本模块"更热"叠加不利） |
| G | 相机/音频/蓝牙解锁（哈苏、马里亚纳、meta_audio、LHDCv5、空间音频、UHDR） | 硬件特性开关。GT8 无马里亚纳/哈苏；`persist.vendor.bluetooth.3rd.lhdcv5.support=true` 会诱导蓝牙栈尝试加载不存在的 LHDC 编码库 | 无效或引发蓝牙/相机服务异常；且与温控主线完全无关 |
| H | `persist.sys.preload/prestart/precache.enable=false`（4 条） | 关闭预加载/预启动，**降低**应用启动速度，与本模块性能诉求相反 | 冷启动变慢、后台保活下降 |
| I | `persist.sys.oplus.platformlevel=c:3,g:3` | 伪装平台等级以解锁游戏画质档位；GT8 已是旗舰档 | 收益≈0，可能解锁更高画质→更热 |
| J | `persist.sys.oplus.wifi.sla.game_high_temperature=50` | 唯一与"温度"沾边的一条。但本模块已把温度骗到 25~30 °C，该阈值**永远不会触发** | 收益≈0；若该值被 SLA 逻辑用于其它判据则存在未知副作用 |

### 2.1 顺带发现的缺陷（可作为本模块的反面规范）

| 位置 | 问题 | 实测/依据 |
|------|------|-----------|
| `post-fs-data.sh:7` | 目标路径写成 `multimedia_display_feature_config.xml`，**缺前导 `/`** | 相对路径挂载必然失败（目标不存在），该条静默失效 |
| `customize.sh:67` | `grep -q 'a' 'b' 'c' file` —— 只有第 1 个是模式，后 2 个被当**文件名** | 本地实测：仅第 1 个关键字生效，其余报 `No such file`，且未命中时 exit=2 而非 1。正确写法 `grep -qE 'a|b|c' file` |
| `customize.sh:24-33` | `Volume_key_monitoring` 用 `while :` + `getevent -qlc 1` 阻塞等输入 | Magisk recovery 下是常规交互；但 **KSU 在 App 内安装，用户看不到提示、也按不到音量键 → 安装挂死**。这是该模块在 KSU 环境下的高危点 |
| `customize.sh:85` | 卸载冲突模块用 `rm -rf "$module_dir"` | 更稳妥是写 `<dir>/remove` 标记；直接删在 `/data/adb/modules_update` 有残留时会清不干净 |
| `customize.sh:59` | `grep -m1 'id='` 无行首锚点 | 会误命中 `versionId=`、`#id=` 等；应 `grep -m1 '^id='` |
| `system.prop` | 3 个重复键（`debug.performance.tuning`、`persist.sys.feature.uhdr.support`、`persist.vendor.bluetooth.3rd.lhdcv5.support`） | 无害但说明未做去重校验 |
| 整体 | `my_product/`、`system/vendor/` 既按模块规范放文件（overlay），又在 `post-fs-data.sh` 手工 bind | 若管理器已支持这些分区 overlay，手工 bind 属**重复挂载** |

---

## 3. 值得复用的 3 处（含具体改法）

### ★1 冲突检测：新增 Tier C —— 按"资源占用"扫描（**建议引入**）

**解决什么问题**
本模块 `common/conflicts.sh` 目前只有两层：

- Tier A：`match_known` 按 id/名称认已知三家（horae / extreme_gt / moka）
- Tier B：`match_keyword` 按名称含 thermal/温控/散热 等关键词猜

两层都**只看"身份"**。遇到没听过的模块（比如这份慕容包、或任何显示/性能模块）就完全静默——但用户反馈里"亮度异常""参数莫名失效"恰恰常来自这类**身份不相关、资源却重叠**的模块。

慕容 `check_conflict_modules` 提供了第三种思路：**翻开对方的文件，看它到底往哪些资源上写。** 这个思路本身有价值，原实现有 bug（见 2.1），应**抽取改造**后引入，而不是照抄。

**为什么适合"抽取为公共逻辑"而不是另起一份**
本模块已在 `module.prop` 声明了 `thermalOwns=` 资源清单（emul_temp、cooling_device、scaling_max_freq、/proc/shell-temp、horae、orms、sys_thermal_config…），Tier C 直接复用这份清单做 token，语义天然一致，且与 Tier A/B 共用同一份 `detect_conflicts` 输出格式（`id|name|version|risk|note`），WebUI / action.sh / 安装期三处消费方**零改动**。

**建议改动位置：`common/conflicts.sh`**

```sh
# ── Tier C：按资源占用扫描（思路来自「慕容ColorOS附加模块」的
#    check_conflict_modules，但重写 —— 原实现 grep -q 多参数写法只匹配了
#    第 1 个关键字，且用 grep 'id=' 无行首锚点、rm -rf 直删、getevent 阻塞）。
#    与 Tier A/B 的区别：A/B 认身份，C 认证据 —— 能抓到没见过的模块。
#    只扫 *.sh / *.prop / *.rc，固定串匹配（-F），单文件命中即停，限 512 KB。
#    默认关闭（SCAN_RESOURCES=0）：有 I/O 成本，只在安装期与手动 conflicts 时开。
scan_resource_hits() {            # $1=模块目录；stdout=命中的 token（去重）
    [ -d "$1" ] || return 0
    find "$1" -type f \( -name '*.sh' -o -name '*.prop' -o -name '*.rc' \) \
         -size -512k 2>/dev/null |
    while IFS= read -r _f; do
        for _t in emul_temp /proc/shell-temp thermal_zone cooling_device \
                  scaling_max_freq horae orms sys_thermal game_thermal max_gpu_clk; do
            if grep -q -F -e "$_t" "$_f" 2>/dev/null; then echo "$_t"; break; fi
        done
    done | sort -u
}
```

在 `detect_conflicts` 的 `match_keyword` 之后追加兜底分支：

```sh
        match_known   "$_id" "$_nm" "$_ver" && continue
        match_keyword "$_id" "$_nm" "$_ver" && continue
        # Tier C：身份认不出，就看它有没有碰同一批资源
        if [ "${SCAN_RESOURCES:-0}" = "1" ]; then
            _hits=$(scan_resource_hits "$_d")
            [ -n "$_hits" ] && echo "$_id|$_nm|$_ver|low|脚本/属性里出现温控资源关键字：$(echo $_hits | tr '\n' ' ')"
        fi
```

**开关与默认值（3 处）**

| 文件 | 改动 |
|------|------|
| `mode.conf` | 新增 `SCAN_RESOURCES=0`（放在 `CHECK_CONFLICTS=1` 下方，注释说明"只在安装期与手动 conflicts 时建议开"） |
| `common/functions.sh` `load_conf()` | 增一行 `SCAN_RESOURCES=$(conf_get "$MODE_CONF" SCAN_RESOURCES 0)` |
| `customize.sh` 冲突自检段 | source 前加 `SCAN_RESOURCES=1 \`（安装期一次性开销可接受，与 `MODULES_DIR`/`SELF_ID` 同一处赋值） |

**副作用 / 依赖 / 冲突**

- **误报**：注释里提到 `emul_temp` 也会命中 → 已固定为 `risk=low`、措辞为"疑似/需人工确认"，不会触发任何自动动作（本库本来就只告警）
- **耗时**：只扫 `.sh/.prop/.rc`、单文件命中即 `break`、`sort -u` 截断输出；实测量级为几十个小文件，安装期 <1 s。**不要在 service.sh 主循环里开**（5 s 一轮会放大 I/O）
- **依赖**：`find -size` / `grep -F` 在 toybox 下均可用；`-maxdepth` 未加（模块目录可能嵌套 webroot），已用 `-size -512k` 兜住大文件
- **与现有实现冲突**：无。输出格式与 `print_conflicts` 完全兼容；`risk=low` 在 `print_conflicts` 里走 `else` 分支显示"· 疑似"，无需改
- **与慕容原版的差异**：不做 `rm -rf`、不调 `getevent`、不阻塞安装（KSU 兼容）

---

### ★2 触控手势参数 `DragMinSwitchSpeed` / `QuietInterval`（**条件引入**）

**解决什么问题**
这三条是 AOSP `PointerGestureClassifier` 的手势判定参数（`dumpsys input` 的 `PointerGesture:` 段可直接读到），默认值：

```
PointerGesture: Enabled: true
  QuietInterval:        100.0ms    ← 手势切换前的静默等待
  DragMinSwitchSpeed:   50.0px/s   ← 拖拽中切换主指针的最小速度
  TapDragInterval:      300.0ms    ← tap 后判定为 drag 的最大间隔
```

本模块 v2.8.3 已从「超频响应 8.3」并入 `TapDragInterval=1`；慕容这份补充了另外两条，且**与已有那条同源互补**：

| 键 | 慕容值 | 默认 | 效果 |
|----|--------|------|------|
| `DragMinSwitchSpeed` | `99999.0px/s` | 50.0 px/s | 阈值拉到不可能达到 → 拖拽中不再切换主指针 |
| `QuietInterval` | `0.0ms` | 100 ms | 去掉手势切换的静默等待 |

**为什么只是"条件引入"**
system.prop 是开机注入、**无法随 `MODE=off` 撤销**（本模块 README 已注明这一约束）。而这两条会改变多指手势判定，与已有的 `TapDragInterval=1` 叠加后，"轻点后立刻拖拽"会明显更敏感——可能增加误触。收益（跟手性）需要实机体感确认，不值得先斩后奏。

**验证方法（先做这一步，再决定是否落地）**

```sh
# 刷入前
su -c 'dumpsys input' | sed -n '/PointerGesture/,/Viewport/p'
# 手动注入（重启前即可验证，无需改包）
su -c 'resetprop DragMinSwitchSpeed 99999.0px/s; resetprop QuietInterval 0.0ms'
# 重启 InputFlinger 生效后重读同一段，确认数值已变，再体感 10 分钟
```

**若验证通过**：直接追加到 `system.prop` 现有触控段（`TapDragInterval=1` 下方），并同步在文件头注释里补一句"这三条同源，出现误触请整段删除"。**不建议**为它新增 mode.conf 开关——system.prop 不受运行时配置控制，加开关会造成"配置里有但没生效"的错觉。

**副作用**：多指拖拽/双指手势行为改变；与 `TOUCH_BOOST=1`（renice）无冲突，二者作用于不同层。

> 慕容 `system.prop` 里另一组 `touch.*`（deviceType / gestureMode / size.calibration / pressure.calibration / orientationAware …）**不建议引入**：AOSP 里这些属于 `.idc` 输入设备配置键，属性注入路径在 ColorOS 上需单独验证；且 `touch.deviceType=touchScreen` 是对所有输入设备的兜底声明，误伤面比收益大。若确实想试，同样先用 `dumpsys input` 的 `Configuration:` 段做前后对比。

---

### ★3 亮度嫌疑清单 + 已知模块名单（**建议引入**，成本极低）

**解决什么问题**
本模块最顽固的故障面是"亮度被钳最低"（`action.sh bsafe` 就是为此建的）。慕容这份包里恰好有**一批会动亮度/显示的东西**，把它记进排查表，用户同时刷了别的模块时 diag 能直接指认嫌疑源，省掉大量往返。

**（a）`action.sh` 的 `diag)` 分支 —— 在现有"亮度/显示相关属性"循环里补 4 个键**

位置：`action.sh` 第 68-71 行的 `_p in ...` 列表，追加：

```
ro.display.brightness.brightness.mode \
persist.oplus.display.pixelworks \
persist.oplus.display.vrr \
persist.sys.oplus.anim_level
```

同时在该分支末尾加一段"第三方显示模块嫌疑提示"：

```sh
echo "=== 已知会改亮度/显示的第三方挂载（非空即嫌疑）==="
for _f in /my_product/etc/refresh_rate_config.xml \
          /my_product/vendor/etc/display_brightness_config_P_3.xml \
          /my_product/etc/oplus_vrr_config.json; do
    [ -s "$_f" ] && echo "  ⚠ $_f 被覆盖（$(wc -c < "$_f") B）"
done
[ ! -s /vendor/etc/perf/perfboostsconfig.xml ] && \
    echo "  ⚠ /vendor/etc/perf/perfboostsconfig.xml 为空 → 高通 perf boost 已被关闭"
```

**（b）`common/conflicts.sh` 的 `match_known` —— 登记这个模块（medium 级）**

```sh
        murongltpo)
            echo "$1|$2|$3|medium|慕容 ColorOS 附加模块：清空 QTI perfboostsconfig/perfconfigstore（关掉高通 perf boost）并全局锁 120Hz，与本模块 UNLOCK_FREQ/TOUCH_BOOST 目标相悖；其 display 配置来自 2024 年固件与其它机型，可能引发亮度/刷新率异常"
            return 0 ;;
```

> 定 `medium` 而非 `high`：它不碰 emul_temp / thermal_zone / cooling_device，不构成温控资源争抢；冲突点是"性能目标相反 + 显示侧副作用"。

**副作用**：纯诊断输出，无运行时行为改变；`diag` 多跑 3 次 `wc -c`，可忽略。

---

## 4. 两模块共存的冲突矩阵（供排查参考）

| 资源 | 本模块 v2.8.5 | 慕容 1.1 | 结果 |
|------|---------------|----------|------|
| `debug.sf.use_phase_offsets_as_durations` | `1` | `true` | 唯一重名键；`GetBoolProperty` 对 `1`/`true` 均判真，**等价，无实质冲突** |
| `TapDragInterval` | `1` | 未设置 | 无冲突 |
| `DragMinSwitchSpeed` / `QuietInterval` | 未设置 | 有 | 无冲突（互补，见 ★2） |
| `emul_temp` / thermal_zone / cooling_device | 独占 | 不碰 | **无温控争抢** |
| `/vendor/etc/perf/perfboostsconfig.xml` | 不碰 | **清空** | QTI boost 消失，部分抵消本模块 `TOUCH_BOOST` |
| `/my_product/...` 显示配置 | 不碰 | 全量替换 | 亮度/刷新率异常的直接嫌疑源 |
| 整机热负载 | 去温控 → 更热 | 锁 120Hz → 更热 | **叠加**：两者同时开启会显著提高机身温度 |

---

## 5. 结论清单

| 项 | 建议 | 整合方式 | 位置 | 工作量 |
|----|------|----------|------|--------|
| 冲突检测 Tier C（资源占用扫描） | ✅ 引入 | 抽取为公共逻辑（改造后） | `common/conflicts.sh`、`mode.conf`、`functions.sh:load_conf`、`customize.sh` | ~25 行 |
| `DragMinSwitchSpeed` / `QuietInterval` | ⚠️ 条件引入 | 直接复用（先实机验证） | `system.prop` 触控段 | 2 行 |
| 亮度嫌疑属性 + 挂载检查 | ✅ 引入 | 直接复用 | `action.sh` `diag)` | ~10 行 |
| `murongltpo` 登记为已知冲突 | ✅ 引入 | 直接复用 | `common/conflicts.sh:match_known` | 5 行 |
| `refresh_rate_config.xml` 等 5 个厂商配置 | ❌ 不引入 | 保持独立 | — | — |
| 空 `perfboostsconfig.xml`（关 boost） | ❌ 不引入（目标相反） | 保持独立 | — | — |
| MTK `power*.xml`（3 个） | ❌ 不引入（平台不符） | 保持独立 | — | — |
| 40+ 条 `debug.sf.*` / `vendor.display.*` | ❌ 不引入 | 保持独立 | — | — |
| 相机/音频/蓝牙特性解锁 | ❌ 不引入（硬件不符） | 保持独立 | — | — |
| `preload/prestart=false`、platformlevel、wifi.sla | ❌ 不引入（收益≈0 或反向） | 保持独立 | — | — |
| `touch.*`（idc 键组） | ❌ 不引入（路径待验证） | 保持独立 | — | — |
| 音量键交互 / `rm -rf` 卸载 / `Outputs sleep` | ❌ 不引入 | 反面规范，写入 `common/conflicts.sh` 注释 | 注释 | 3 行 |

**一句话**：这份包对本项目最大的价值不是它的功能，而是**提示了一条更好的冲突检测维度**；其余资产要么平台不符、要么机型不符、要么与本模块目标相反，引入只会增加复杂度和故障面。

---

## 6. 落地状态（v2.8.6，2026-10-04 已实施）

评审结论已在 `RealmeGT8-SukiSU-ThermalRemove` v2.8.6 / versionCode 37 上落地，产出
`RealmeGT8-SukiSU-ThermalRemove-v2.8.6.zip`（23 文件 / 71 614 B / CRC OK / 无 CRLF）。

| 项 | 状态 | 说明 |
|---|---|---|
| ★1 Tier C 资源占用扫描 | ✅ 已落地 | `common/conflicts.sh` 新增 `scan_resource_hits()` + Tier C 分支；`mode.conf` 新增 `SCAN_RESOURCES=0`；`functions.sh:load_conf` 读取；`customize.sh` 与 `action.sh conflicts` 强制置 1 |
| ★2 触控手势参数 | ⏸ 条件保留 | 以**注释形式**写入 `system.prop`（`#QuietInterval` / `#DragMinSwitchSpeed`），附 `dumpsys input` 验证步骤；待实机确认后再取消注释 |
| ★3 亮度嫌疑清单 + 已知名单 | ✅ 已落地 | `action.sh diag` 补 4 个属性 + 第三方显示配置覆盖检查；`match_known` 登记 `murongltpo` 为 medium |
| 其余 | ❌ 未引入 | 保持独立 |

**实施期相对评审方案的两处调整（均为工程细节，方向未变）**

1. `scan_resource_hits` 原本设计成"每个关键字跑一次 grep"（文件数 × 10 次 fork）。
   实测改为**两段式**：先用一次 grep 带全部关键字判断「有没有」，命中才逐 token 定位。
   绝大多数模块不会命中 → 每文件仅 1 次 fork；命中才付 10 次。
   同时刻意**不用 `grep -o` 一把梭**——toybox 的 `-o` 支持情况不一致，一旦不支持会静默丢结果。
2. `print_conflicts` / WebUI 无需改动：`risk=low` 与 `medium` 共用「· 疑似」样式，
   `index.html` 的 `risk === 'high' ? 'hi' : 'mid'` 已天然覆盖。

**冒烟测试**（模拟 6 个模块：`self` / `murongltpo` / `unknown_display` / `xmlonly` / `disabled` / `big(1MB 脚本)`）

- `SCAN_RESOURCES=0`：只报 `murongltpo`（medium）—— 自身排除、已禁用跳过 ✓
- `SCAN_RESOURCES=1`：追加 `unknown_display`（low，`emul_temp thermal_zone`）—— 身份认不出但脚本写温控资源 ✓
- 只有 `.xml` 的模块不被扫描、>512 KB 脚本被 `-size` 跳过 ✓
