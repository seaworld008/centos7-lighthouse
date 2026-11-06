# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。
每条变更标注验证状态：`verified-on-real-run` / `container-smoke` / `untested`。

## [Unreleased]

### Added
- `convert-el8.sh`：源系统为 CentOS Linux 8 / Stream 8 时，先用官方 almalinux-deploy 转成 AlmaLinux 8，再走 8→9→10。子命令为 `prep` / `update` / `run` / `post`（`verified-on-real-run`，阿里云）
- `survey.sh`：CentOS 8 源系统报 BLOCKER；`epel.repo` 版本与系统不一致报 HIGH；nginx 跑在容器里时不再误报"文件不存在"
- `state.sh`：能读出容器里 nginx/openresty/tengine 的 server_name；老版本 nginx 没有 `-T` 时直接读配置文件；所有 TCP 端口按 IP 探测，443 用 https
- `verify.sh`：新版本 unit 因启动条件不满足而跳过（如 sssd 无配置）时视为预期
- `hop.sh answer`：8→9 自动处理 firewalld `AllowZoneDrifting` 阻断项（只改配置，不 reload）
- `hop.sh prep`：按 `.sigs` 签名 key 判断本机在用的厂商源，只探测这些（docker-ce 的 PES 是空的）
- `hop.sh answer`：9→10 自动执行 `nmcli connection migrate`，并对比迁移前后的地址和默认路由
- `hop.sh post`：先等 leapp FirstBoot（`leapp_resume.service`）结束再清理；禁用只有 metalink 的 epel-cisco-openh264
- `verify.sh`：dbus → dbus-broker 映射；30 秒内 RestartCount 仍在增长的容器判为 FAIL（crash-loop 检测）
- 实战报告：[阿里云堡垒机 CentOS 8.3 → AlmaLinux 10.2](field-reports/2026-11-06-aliyun-bastion-docker-centos8.md)

### Fixed
- `hop.sh pre` 末尾调用 `"$0" report` 时，因为 SFTP 上传的文件没有执行权限而报 Permission denied → 改为 `bash "$0"`（`verified-on-real-run`）
- `convert-el8.sh` 自建的 vault 源与 AlmaLinux 的 repo id 冲突，导致 distro-sync 实际同步回 CentOS → 改用 `c8vault-*` 并在转换前移走（`verified-on-real-run`）
- `hop.sh post` 与 leapp_resume 竞争，导致 FirstBoot 中断（`verified-on-real-run`：9→10 时已正确等待）
- `hop.sh report` 在 EL7（py2）和 EL8（py3.6）的 `LC_ALL=C` 环境下输出中文时崩溃（由 CI 冒烟测试发现）

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
