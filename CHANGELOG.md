# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。
每条变更标注验证状态：`verified-on-real-run` / `container-smoke` / `untested`。

## [Unreleased]

## [0.3.1] - 2026-11-06

第二台全程用脚本完成的 CentOS 7（阿里云测试应用机，7.9 → AlmaLinux 10.2，约 1.9 小时）。见 [实战报告](field-reports/2026-11-06-aliyun-test-apps-hostmysql-centos7.md)。

### Fixed（均为 `verified-on-real-run`）
- `prep-el7.sh repos`：不可达的第三方源（如 netbird）会让 `yum repolist` 卡 20 分钟 → 改为逐个用 curl 探测，不通就禁用；挪走所有 `CentOS-*.repo`；repolist 加超时（实测 33 秒）
- `prep-el7.sh inhibitors`：先删旧内核，再重建 initramfs
- `hop.sh post`：自动禁用并挪走源码安装的 cloud-init unit（阿里云老镜像，三台机器都遇到）
- Release 工作流：标题里的 markdown 链接只保留文字

### Verified
- 上一版新增的 7→8 驱动卸载、EL7 内核 `--noscripts` 删除、9→10 的 dhclient/ifcfg 自动处理，在第二台机器上全部无需人工干预

## [0.3.0] - 2026-11-06

第一台全程用脚本完成的 CentOS 7（阿里云多业务机，7.6 → AlmaLinux 10.2；Closes #5）。见 [实战报告](field-reports/2026-11-06-aliyun-registry-waf-lnmp-centos7.md)。

### Added
- `prep-el7.sh netmgr`：network.service → NetworkManager，失败自动回滚（`verified-on-real-run`）
- `hop.sh answer`：7→8 时卸载 floppy/pata_acpi；8→9 时遇到 ifcfg "unsupported device types" 用 `nmcli connection migrate` 处理；9→10 时处理 `dhcp=dhclient`（/etc 里的注释掉，/usr/lib 下不属于任何包的残留文件挪走）（`verified-on-real-run`）
- `hop.sh reboot --no-stop`：业务方要求某些容器不能动时，不提前停止任何容器
- `survey.sh`：/usr/lib 下的 dhcp=dhclient 报 HIGH；ifcfg 缺 `TYPE=` 报 MEDIUM；启用了 iptables.service 报 INFO
- 文档：Harbor 开机 syslog 日志驱动竞争（autostart unit）、ssmtp 被删、LNMP 日志目录 777 导致 logrotate 跳过

### Fixed（均为 `verified-on-real-run`）
- `hop.sh post`：EL7 内核的 %preun 调用 new-kernel-pkg（exit 127）导致删不掉 → `rpm -e --noscripts` 后清理 /boot、/lib/modules 和启动项
- `prep-el7.sh inhibitors`：黑名单文件里混进了 "rmmod" 行；写黑名单后重建 initramfs，避免重启后模块再次被加载
- `nginx-static-build.sh`：`--with-openssl-opt` 被截断；老版本签名公钥改从 keyserver 获取；sha256 不符时删除文件并提示手动上传；`--install` 参数被 `set --` 覆盖；用 mv 替换运行中的二进制
- `hop.sh prep`：同名第三方包已安装（leapp 装的 docker-ce 没有签名）也算作在用的厂商源

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
