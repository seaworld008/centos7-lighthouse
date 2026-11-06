# Roadmap

方向：从"一次成功的经验"走向"任何一台 CentOS 7 都能被 agent 安全、可预期地升级"。

## v0.2 — 回归实测（v0.2.0 已发布，剩余项转入 v0.2.x）
- [x] 第一次全程使用脚本的真实执行：阿里云 CentOS 8.3 → AlmaLinux 10.2，并新增 CentOS 8 源路径（`convert-el8.sh`）
- [x] `prep-el7.sh` repos/pipfix/inhibitors 与 `swap-openssh.sh` 的检测路径进入 CI（centos:7 容器中真实执行）
- [ ] 在真实 CentOS 7 上只用脚本跑完一次（7→8 这一跳、`prep-el7.sh update`、`swap-openssh.sh` 的实际替换）——[#5](https://github.com/seaworld008/centos7-lighthouse/issues/5)
- [x] 阿里云首份 field report
- [ ] AWS 首份 field report——[#7](https://github.com/seaworld008/centos7-lighthouse/issues/7)
- [x] `fleet_summary.py`：汇总多台 survey → 分类 → 金丝雀与批次建议（[#6](https://github.com/seaworld008/centos7-lighthouse/issues/6)）

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
