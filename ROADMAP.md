# Roadmap

方向：从"一次成功的经验"走向"任何一台 CentOS 7 都能被 agent 安全、可预期地升级"。

## v0.2 — 回归实测
- [ ] 在全新的 CentOS 7 机器上，从头到尾只用脚本跑完一次，修掉执行类子命令的问题，把状态从 `untested` 改成 `verified`
- [ ] 补齐阿里云和 AWS 的首份 field report
- [ ] `tools/fleet_summary.py`：汇总多台机器的 `survey.txt`，按 BLOCKER/HIGH 分类，输出升级批次建议

## v0.3 — 可评测
- [ ] 用 `claude plugin eval` 写技能评测用例：勘察结论是否正确、是否在该问用户时停下、是否误删组件
- [ ] CI 中用带 KVM 的 runner 启动 CentOS 7 虚拟机，真实跑一遍 ELevate（至少 7→8）

## v0.4 — 更多路径
- [ ] 目标可选 Rocky Linux / AlmaLinux 9（到 9 为止）
- [ ] 针对 CPU 不满足 x86-64-v3 的机器，支持 AlmaLinux 10 x86_64_v2
- [ ] "不原地升级"路线：新建机器 + 迁移业务的标准流程

## 持续进行
- 每次真实执行都写 field report，并把经验提炼进 pitfalls、检测和脚本
- 英文文档同步（`references/` 的英文版）

欢迎通过 issue 认领或提出新方向。
