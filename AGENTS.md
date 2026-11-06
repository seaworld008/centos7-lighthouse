# AGENTS.md — 给维护本仓库的 AI Agent

本仓库主要由 AI agent 阅读、执行、改进和沉淀经验。人类维护者负责审核与决策。开始任何工作前请先读完本文件（约 5 分钟）。

## 使命
给仍在使用 CentOS 7 的人一条可靠的路：**把服务器安全地原地升级到 AlmaLinux 10，业务不断**。所有改动都服务于这三点：
1. **安全**：不失联，可回滚，不丢数据
2. **可验证**：升级前后用基线对比，而不是凭感觉
3. **可复用**：每次真实执行的经验都要沉淀成文档、检测和脚本

## 仓库地图
| 路径 | 作用 | 什么时候改 |
|---|---|---|
| `skills/centos7-almalinux-upgrade/SKILL.md` | 技能主流程，被 Claude 加载 | 流程/原则变化（保持 < 500 行，细节放 references） |
| `skills/.../scripts/` | 在目标机执行的脚本 + 本机 `remote.py` | 修 bug、自动化新处理 |
| `skills/.../references/pitfalls.md` | 坑：现象 → 原因 → 处理 | 每个新问题 |
| `skills/.../references/app-compat.md` | 各类应用跨版本处理 | 新的应用类型 |
| `skills/.../references/cloud-providers.md` | 云厂商差异 | 新云/新发现 |
| `skills/.../references/recovery.md` | 救援 | 新的故障形态 |
| `skills/.../references/fleet.md` | 批量推进 | 流程改进 |
| `field-reports/` | 每次真实执行的脱敏报告 | **每次真实执行后必写** |
| `tools/check_repo.py` | 仓库自检（结构、版本一致、敏感信息） | 新规则 |
| `tests/container-smoke.sh` | 在 CentOS 7 / AlmaLinux 8/9/10 容器里跑脚本冒烟测试；会修改系统的测试只在 `/.dockerenv` 存在时运行 | 新脚本/新子命令 |
| `tests/test_*.py` | Python 工具的单元测试（unittest，标准库） | 改 `fleet_summary.py` 等时 |
| `.claude-plugin/` | Claude Code 插件与 marketplace 清单 | 发版时改版本号 |
| `CHANGELOG.md` | 变更记录 | 每个 PR |

## 铁律
1. **绝不提交敏感信息**：真实 IP、域名、主机名、账号、密码、密钥、客户/公司名、私有镜像仓库地址。示例统一用 `10.0.0.x`、`example.com`。提交前必须 `python tools/check_repo.py` 通过（CI 还有 gitleaks）。
2. **诚实标注验证状态**：只在真实机器上跑通过的才写"已验证"。CHANGELOG 和 PR 描述里区分 `verified-on-real-run` 与 `untested`。
3. **脚本兼容性**：`scripts/*.sh` 必须在 EL7 到 EL10 都能运行：
   - bash 4.2，不用 `ss -H`、`mapfile -d`、`${var@Q}` 等新特性
   - EL7 上没有 python3，需要 Python 的地方用 `$PY` 回退到 python2
   - 内嵌 Python 第一行写 `# -*- coding: utf-8 -*-`，并加 `from __future__ import print_function, unicode_literals`；调用时加 `PYTHONIOENCODING=utf-8`。原因：脚本都设置了 `LC_ALL=C`，在这种环境下 py2 和 py3.6 输出中文会直接崩溃。EL10 的 py3.12 不会崩，所以只在新系统上测试发现不了（CI 冒烟测试因此抓到过这个问题）
   - 每个 `for f in dir/*` 都要先判断 `[ -e "$f" ] || continue`
   - 不依赖可能缺失的命令；缺失时要优雅降级
4. **只读脚本保持只读**：`survey.sh`、`state.sh`、`verify.sh`、`hop.sh report|status` 不得修改系统。
5. **长任务用 `systemd-run` 后台执行并轮询**，不要让一个 SSH 会话挂着跑 leapp/dnf。
6. **`pkill -f` / `pgrep -f` 的模式不能出现在自己的命令行里**：按 PID 操作，或用 `[x]xx` 写法。
7. **会改变业务行为的事由人决定**：删组件、下线站点、关闭旧 TLS 协议、数据库大版本升级、回滚。技能里写成"向用户确认"，不要写成自动执行。
8. **不要让 Agent 代输密码**：控制台登录由人完成；脚本里不打印、不在命令行参数中传递密码。

## 沉淀经验的工作流（最重要）
每次真实执行（无论成败）：
1. 按 `field-reports/TEMPLATE.md` 写 `field-reports/YYYY-MM-DD-<cloud>-<profile>.md`（脱敏），并更新 `field-reports/README.md` 的索引表。
2. 对报告里每个新问题判断：
   - 以后还会遇到 → 写进 `pitfalls.md`（放到对应的跳或阶段，带"现象 → 原因 → 处理"）
   - 能自动检测 → 在 `survey.sh` 加 `flag`（分级：BLOCKER 会失联、失败或丢数据；HIGH 会导致业务坏；MEDIUM 需要处理；INFO 提示）
   - 能自动修复 → 改进对应脚本，并给 `tests/container-smoke.sh` 加覆盖
   - 只是这一台的特例 → 只留在报告里
3. 在报告的问题小节标注 `状态：promoted → <位置>`。
4. 更新 `CHANGELOG.md` 的 `[Unreleased]` 段。

## 本地自检
```bash
python tools/check_repo.py                 # 结构、版本一致性、敏感信息、SKILL.md 引用的文件都存在
bash -n skills/*/scripts/*.sh               # 语法
python -m unittest discover -s tests        # fleet_summary.py 等 Python 工具的单元测试
shellcheck -S warning -e SC2010 -s bash skills/*/scripts/*.sh tests/*.sh
bash tests/container-smoke.sh               # 需要 docker；CI 会在 centos:7 / almalinux:8/9/10 跑
claude plugin validate .                    # 插件/marketplace 清单
```

## 提交与发版
- 分支 + PR；Conventional Commits（`feat:`、`fix:`、`docs:`、`pitfall:`、`report:`、`ci:`）；squash 合并。
- PR 描述说清楚：改了什么，为什么改，验证状态（真实机器 / 容器冒烟 / 未测）。
- 发版（semver）：
  1. 同步修改 `.claude-plugin/plugin.json` 的 `version`，以及 `marketplace.json` 里的 `metadata.version` 和 `plugins[0].version`
  2. 把 `CHANGELOG.md` 的 `[Unreleased]` 改成新版本号
  3. `check_repo.py` 会校验三处版本号与 CHANGELOG 一致
  4. 提 PR，CI 通过后合并。`Release` 工作流检测到 main 上 `plugin.json` 的版本变化后，会自动打 `vX.Y.Z` 标签，并用 CHANGELOG 对应段落发布 Release。不要手工打标签
- 分支：仓库只长期保留 `main`。PR 合并后分支会自动删除；main 有保护，必须通过 CI

## 常见任务 → 去哪里
| 任务 | 入口 |
|---|---|
| 给某台服务器做升级 | 加载技能，按 `SKILL.md` 执行，结束后写 field report |
| 遇到没见过的报错 | 先搜 `pitfalls.md`、`recovery.md`，再搜 `field-reports/` |
| 新增一种业务/应用的兼容处理 | `app-compat.md` + 必要时 `finalize.sh` 新子命令 |
| 新增一个云厂商 | `cloud-providers.md` + `survey.sh` 的云识别 + `prep-el7.sh` 镜像说明 |
| 改进触发描述 | `SKILL.md` frontmatter 的 `description` |
