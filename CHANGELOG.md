# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。
每条变更标注验证状态：`verified-on-real-run` / `container-smoke` / `untested`。

## [Unreleased]

### Changed
- ci: actions/checkout v7、setup-python v7、setup-node v7、gitleaks-action v3（Node 24 运行时）

## [0.1.0] - 2026-11-06

首个公开版本，提炼自一次真实生产迁移（华为云，CentOS 7.7 → AlmaLinux 10.2）。见 [field report](field-reports/2026-11-05-huawei-jumphost-docker-vpn.md)。

### Added
- 技能 `centos7-almalinux-upgrade`（Claude Code skill + plugin + marketplace）
- 脚本
  - `remote.py`：读取资产表的 SSH 执行器，开启 keepalive，支持 `--sudo`，自动还原 Git Bash 的路径改写（`verified-on-real-run`）
  - `survey.sh`：只读勘察，输出分级风险清单（`verified-on-real-run` EL10，`container-smoke` EL7–10）
  - `backup.sh` / `state.sh` / `verify.sh`：备份、业务基线与对比（`verified-on-real-run` EL10，`container-smoke` EL7–10）
  - `hop.sh`：逐跳 prep / pre / report / answer / up / reboot / post。`report` 已实测（`verified-on-real-run`），其余执行类子命令由真实迁移中的命令整理而成（`untested` as a script）
  - `prep-el7.sh`、`swap-openssh.sh`、`nginx-static-build.sh`、`finalize.sh`（`untested` as scripts；对应的手工步骤 `verified-on-real-run`）
- 文档：`pitfalls.md`、`app-compat.md`、`cloud-providers.md`（阿里云/华为云/AWS）、`recovery.md`、`fleet.md`
- 仓库基础设施
  - 面向 AI agent 的 `AGENTS.md`
  - `field-reports/` 经验沉淀机制
  - `tools/check_repo.py` 自检
  - 在 CentOS 7 / AlmaLinux 8/9/10 容器中运行的冒烟测试
  - CI：shellcheck、插件校验、gitleaks
  - issue/PR 模板
