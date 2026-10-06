# GT8 ThermalRemove

真我 GT8（RMX6699 / 骁龙 8 至尊版 SM8750 / Android 16）的温控移除 KernelSU/SukiSU 模块，
附一套完整的**本地行为等价性回归台**与 **CI 流水线**。

- 模块源码：`GT8-ThermalRemove/`（可打包为 KernelSU 可刷 zip）
- 回归套件：`_analysis/regress/verify.sh`（249 项断言，Windows / Linux 均可跑）
- CI：`.github/workflows/ci.yml`（push 自动：语法检查 → 回归 → 打包校验）

---

## 目录结构

| 路径 | 内容 |
|---|---|
| `GT8-ThermalRemove/` | 模块交付目录（`module.prop` + 全部脚本/配置/WebUI） |
| `_analysis/regress/verify.sh` | 行为等价性回归套件（唯一被纳入版本库的测试脚本） |
| `_analysis/regress/pack.py` | 打包 + 解包校验脚本（唯一被纳入版本库的打包脚本） |
| `.github/workflows/ci.yml` | CI 流水线定义 |
| `mod_review/` | 同类模块（HORAE / Extreme GT / Moka 等）的解包评审资产 |
| 其余 `*.md` | 各阶段的评审、诊断、规划文档（见下方索引） |

> `_analysis/` 下其余内容（假 sysfs 树、诊断包、临时补丁脚本等）已通过 `.gitignore` 排除，
> 不在版本库内；`_img/`、`.workbuddy/` 等个人/中间产物同样不入库。

## 快速开始

### 打包模块

```bash
python3 _analysis/regress/pack.py
```

产出 `GT8-ThermalRemove-v*.zip` 并自动解包校验（版本号、关键代码、README、文件清单）。

### 跑回归

```bash
bash _analysis/regress/verify.sh
```

零依赖（仅需 `bash` + `python3`），用「假 sysfs 树 + 路径改写副本 + 命令桩」把模块
变成可本地回归的单元，不写真实 `/sys`、`/data`。

### 真机体检（安装模块后）

```sh
su -c sh /data/adb/modules/realme-gt8-sukisu-thermal-remove/action.sh doctor
```

一条命令出 8 节只读报告：环境支持 / 温感命中 / 欺骗状态 / 冲突 / 风险 / 依赖权限等。

## 版本

| 项 | 值 |
|---|---|
| 当前版本 | v2.13.1（versionCode 66） |
| 回归断言 | 249 项，全部通过 |
| 版本规范 | 三段 SemVer（修订=bug 修复，次版本=新增功能，主版本=破坏性变更；数字为整数非十进制位） |

模块级详细更新日志见 [`GT8-ThermalRemove/README.md`](GT8-ThermalRemove/README.md)。

## CI

- 触发：push / pull request 到 `main`
- 步骤：全部 shell 脚本 `bash -n` → 回归套件 → 打包校验 → 上传 zip artifact
- 本机等价命令：`bash -n` 全部脚本 + `bash _analysis/regress/verify.sh` + `python3 _analysis/regress/pack.py`

## 文档索引

- [升级路线规划](升级路线规划-v2.12到v3.0.md) —— 后续功能/架构/体验/长期演进的方向与分期
- [v2.12.0 实现与验证说明](v2.12.0-实现与验证说明.md) —— 温度保险丝 / 安全模式 / 兼容性修复
- [充电优化集成可行性评估](充电优化集成可行性评估.md) —— 充电限流控制律集成方案
- `代码审核-*.md` / `性能审核与优化-*.md` / `省电优化-*.md` —— 各版本评审与优化记录
- `模块评审-*.md` / `模块解析-*.md` —— 同类模块横向对比
