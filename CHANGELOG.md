# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。
每条变更标注验证状态：`verified-on-real-run` / `container-smoke` / `untested`。

## [Unreleased]

## [0.2.0] - 2026-11-06

第一次全程使用技能脚本的真实执行（阿里云，CentOS 8.3 → AlmaLinux 10.2），新增 CentOS 8 源路径和批量工具。

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
- `bgrun`（hop.sh / convert-el8.sh / prep-el7.sh）把后台命令的退出码传出来；`convert-el8.sh update` 失败或升级后仍低于 8.4 时停止
- `hop.sh post`：镜像改写覆盖所有 `epel*.repo`（含 EL8 的 epel-modular，并设 `skip_if_unavailable=1`），只排除 cisco-openh264
- 实战报告：[阿里云堡垒机 CentOS 8.3 → AlmaLinux 10.2](field-reports/2026-11-06-aliyun-bastion-docker-centos8.md)

### Fixed
- `hop.sh pre` 末尾调用 `"$0" report` 时，因为 SFTP 上传的文件没有执行权限而报 Permission denied → 改为 `bash "$0"`（`verified-on-real-run`）
- `convert-el8.sh` 自建的 vault 源与 AlmaLinux 的 repo id 冲突，导致 distro-sync 实际同步回 CentOS → 改用 `c8vault-*` 并在转换前移走（`verified-on-real-run`）
- `hop.sh post` 与 leapp_resume 竞争，导致 FirstBoot 中断（`verified-on-real-run`：9→10 时已正确等待）
- `hop.sh report` 在 EL7（py2）和 EL8（py3.6）的 `LC_ALL=C` 环境下输出中文时崩溃（由 CI 冒烟测试发现）

### Added (tooling)
- Release 工作流：main 上版本号变化后，自动从 CHANGELOG 生成 Release（`tools/changelog_section.py`）
- `fleet_summary.py`：汇总多台机器的 survey 结果 → A/B/C/D 分类、VPN/EL8 标记、金丝雀与分批建议（`--groups` 让同业务主备不同批）（#6；单元测试 + 真实数据）
- CI：单元测试；centos:7 容器中真实执行 `prep-el7.sh repos/pipfix/inhibitors` 与 `swap-openssh.sh` 的检测路径（会修改系统的测试只在容器里运行）
- `swap-openssh.sh`：没装 openssh-server 时直接退出
- `.github/release.yml` 按标签生成发布说明分类；CODEOWNERS；main 分支保护（必须通过 CI）

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
