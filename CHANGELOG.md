# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)。
每条变更标注验证状态：`verified-on-real-run` / `container-smoke` / `untested`。

## [Unreleased]

两台运行了 861 / 1529 天、很复杂的 PHP + 中间件测试机（阿里云）：CentOS 7.6 / 7.9 → AlmaLinux 10.2，约 3.3 小时，期间修了 8 处脚本问题。见 [实战报告](field-reports/2026-11-08-aliyun-php-middleware-x2.md)。

### Added（均为 `verified-on-real-run`）
- `hop.sh prep`（目标 ≥9）：运行中的非 rpm 程序依赖 `libcrypt.so.1`（静态重编的 nginx、源码编译的 mysqld 5.7）时，把 `libxcrypt-compat` 写进 `/etc/leapp/transaction/to_install`，升级重启后直接能起来
- `hop.sh post`（到 EL8 时）：删除 EL7 的 SCL 残留（rh-*/devtoolset-*/llvm-toolset-*），否则 8→9 报 `Detected RPMs with RSA/SHA1 signature`；有进程在用 /opt/rh 时不删
- `prep-el7.sh inhibitors` 第 5 步：宿主机已没有 Remi PHP 时，删除孤立的 Remi 兼容库（libwebp7/libzip5/libicu69…），否则 7→8 在 `dnf_package_download` 文件冲突（preupgrade 查不出来）
- `nginx-static-build.sh`：`NGX_OPENSSL` / `NGX_OPENSSL_SHA256` 指定 OpenSSL 版本（原二进制已是 OpenSSL 3.x 时不降回 1.1.1）；装 OpenSSL 3 Configure 需要的 perl 模块
- `survey.sh`：残留 Remi 兼容库 → MEDIUM；非 rpm 程序依赖 libcrypt.so.1 → INFO；nginx `add_header` 头名带冒号（HTTP/2 客户端会 PROTOCOL_ERROR）→ INFO
- `pitfalls.md`：第三方源让 `yum update` 整个失败（MySQL 换签名密钥、ob-deploy 自冲突）；长期不重启的机器先在 EL7 重启一次；SHA1 签名第三方包用 `rpm -e --justdb` 保留文件

### Fixed（均为 `verified-on-real-run`）
- ★ `state.sh`：Docker < 20.10 的 `docker ps --format` 没有 `{{.State}}`，基线里一个容器都没记 → 失败时改用 `{{.Status}}` 推出状态
- `state.sh`：HTTP 探测固定 `--http1.1`。EL8+ 的 curl 默认走 h2，遇到非法响应头直接 000，与 EL7 基线不可比（误报 9 个站点）

## [0.4.0] - 2026-11-07

第一次 Kubernetes 集群原地升级：阿里云 kubeadm 1.21 测试集群 3 master + 3 worker，CentOS 7 → AlmaLinux 10.2，**K8s 版本不变**（dockershim + Docker 29 + cgroup v2 实测可用）。见 [实战报告](field-reports/2026-11-07-aliyun-k8s-1.21-3m3w.md)。

### Added（均为 `verified-on-real-run`）
- `k8s.sh`：`backup`（etcd 快照、/etc/kubernetes、二进制、pod 列表、资源 YAML；自动 `pin`）、`pin`（k8s 源 exclude kubelet/kubeadm/kubectl/cni/cri-tools，防止 `dnf upgrade` 升 minor）、`stop`（停 kubelet 后按 业务→控制面→etcd 顺序停容器；`hop.sh reboot` 遇到 kubelet 自动调用）、`nfs-off`/`nfs-on`（leapp 的 NFS 阻断项）、`nm`（NM 不接管 cni0/flannel/veth 等）、`fix`（modules-load.d、sysctl、删 Dead 容器、cgroup 驱动一致性）、`check`、`pods`（与升级前按 namespace 对比）、`jvm-maxram`（cgroup v2 下老 JDK 认不出内存限制 → 注入 `JAVA_TOOL_OPTIONS=-XX:MaxRAM=$(limits.memory)`）
- `references/kubernetes.md`：开工前要弄清的事、兼容性结论、推荐顺序、踩坑表、恢复检查清单
- `finalize.sh`：`iptables-legacy`（容器内 legacy iptables，如 wg-easy）、`redis-valkey`、`manual-procs`（升级前手工启动的进程 → systemd 服务）；`postfix-lmdb` 在禁用 IPv6 时改 `inet_protocols=ipv4`
- `backup.sh`：记录从 SSH 会话手工启动、正在监听端口的进程（cmdline/cwd/exe/环境变量）
- `survey.sh`：fstab bind 到 /sys|/proc|/dev|/run → BLOCKER；rpm 重复包 → HIGH；手工启动的服务进程 → HIGH；K8s 节点 BLOCKER 改为指向 kubernetes.md，并提示 cgroup v2 老 JDK
- `recovery.md` B2：升级环境里很早进 emergency、VNC 敲不了命令（shell 在 ttyS0）；看串口日志；用 noVNC JS 抓 1 秒的 GRUB 菜单回旧内核

### Fixed（均为 `verified-on-real-run`）
- ★ `hop.sh up`：leapp 把 fstab 固化进升级 initramfs，bind 到 /sys 的条目（阿里云 `set_ecs_special.sh`）会让升级环境进 emergency → `leapp upgrade` 前自动注释（`#osup-bind#`），EL10 的 `post` 恢复
- `hop.sh answer`：`ifcfg-*.bak/.orig/.old/~` 备份副本会让 8→9 一直报 unsupported device types → migrate 前挪走
- `prep-el7.sh update`：排除 `kube*`、`cri-tools`
- `prep-el7.sh inhibitors`：保留"最新已安装内核"的 kernel-devel（而不是运行中的），避免 update 后出现两个
- `state.sh`：不把 kubelet 管理的 `k8s_` 容器、127.0.0.1 上的临时端口（如 dockershim 随机端口）记进基线
- `verify.sh`：先判断 unit 是否还存在。已卸载的 unit 也会返回 `ConditionResult=no`，以前会被误报为"条件不满足、预期跳过"，现在报 WARN，交给人判断（`verified-on-real-run`）
- `hop.sh`：改写镜像时的 `.orig` 备份放到工具目录，不再留在 `/etc/yum.repos.d`

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
