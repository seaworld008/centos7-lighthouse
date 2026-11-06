# 避坑手册（现象 → 原因 → 处理）

带 ★ 的是真实迁移中实际踩到的。

## 目录
1. 通用：远程操作
2. EL7 准备阶段
3. 7 → 8
4. 8 → 9
5. 9 → 10
6. 每跳重启后
7. 升级后应用层

---

## 1. 通用：远程操作

**★ SSH 会话 5 分钟左右被断，长命令执行到一半没了**
- 原因：sshd_config 里 `ClientAliveInterval 300` + `ClientAliveCountMax 0`，在 OpenSSH < 8.2 上表示"空闲就断"。换回 7.4/8.0 官方 openssh 后行为出现。
- 处理：客户端开 keepalive（remote.py 已开）；leapp/dnf 这种长任务用 `systemd-run` 后台跑并写日志，再轮询（hop.sh 已这样做）。

**★ `pkill -f "xxx"` 把自己的会话杀了，返回 exit -1**
- 原因：`pkill -f` 匹配完整命令行，你远程执行的 `bash -c "...pkill -f 'leapp preupgrade'...; nohup leapp preupgrade"` 里本身就包含这个字符串。
- 处理：按 PID 杀；或用 `pgrep -f "[l]eapp preupgrade"` 这种写法（正则不匹配自身字面量，但注意同一命令行里别再出现未加括号的原文）；或把命令写进脚本文件执行。

**★ Windows Git Bash 下传 `/root/xxx` 参数变成 `C:/Program Files/Git/root/xxx`**
- 原因：MSYS 路径转换。
- 处理：remote.py 已自动还原；其它工具可设 `MSYS_NO_PATHCONV=1`。

**★ 远程执行 `yum check` 等极慢命令导致本地工具超时**
- 处理：不需要的检查别跑；需要的放后台。

## 2. EL7 准备阶段

**CentOS 7 官方源已下线 / repo 文件重复定义（"Repository base is listed more than once"）**
- 处理：`prep-el7.sh repos <MIRROR>` 统一成 centos-vault 7.9.2009 一个文件；不可达的第三方源自动禁用（否则 yum/leapp 卡住）。

**★ `prep-el7.sh repos` 卡住 20 分钟：卡在 `yum repolist enabled`**
- 原因：机器上有访问不了的第三方源（例如 pkgs.netbird.io），yum 对每个源都会长时间重试。
- 处理：现在改为用 `curl -m 15` 逐个探测每个启用源的 repomd.xml（或 mirrorlist），不通就 `enabled=0`。实测 33 秒完成。另外所有 `CentOS-*.repo`（Vault、Debuginfo、Media 等）都会被挪走。

**★ `yum update` 时某个 python 包 "Failed"：`cpio: rename` / `unpacking of archive failed`**
- 原因：以前有人 `pip install` 到了系统 site-packages（例：pip 装的 urllib3 目录占了 rpm 要放的位置）。
- 处理：`prep-el7.sh pipfix`：挪走所有不属于 rpm 的 site-packages 文件（备份可还原），重装被覆盖的 python rpm，补装失败的包。**每一跳前都要再查一次**（hop.sh prep 会做）。

**★ openssh 是自编译 rpm（如 9.8p1，vendor 为空，SysV 启动脚本）**
- 风险：leapp 不升级非官方包；它链接的 EL7 库/SysV 脚本到新系统上失效 → sshd 起不来 → 失联。
- 处理：`swap-openssh.sh`：用官方 sshd 先 `-t` 测现有配置，备份旧二进制，systemd-run 脱离会话替换，端口没起来就用旧 sshd 兜底。替换后立即用新连接验证。
- 注意：9.x 自编译版的会话进程是 `/usr/libexec/openssh/sshd-session`，换包后旧监听进程再 fork 新会话会失败，所以换完必须立刻重启 sshd（脚本已处理）。

**★ 还在用 `network.service`（NetworkManager 没运行）**
- 风险：EL8 起以 NetworkManager 为准，EL9 起已经没有 network-scripts。
- 处理：`prep-el7.sh netmgr`：安装并启用 NM，去掉 `NM_CONTROLLED=no`，在后台切换；检查默认路由和外网访问，失败就自动回滚到 network.service。然后**在 EL7 上重启一次**，确认切换在重启后依然生效。

**★ yum update 装了新内核，但运行的还是旧内核** → leapp 要求当前运行的是最新内核，所以 7→8 之前要先在 EL7 上重启一次（可以和上面的 NM 验证一起做）。

**★ Harbor 机器重启后，core/registry/nginx 等容器全部 exited：`failed to initialize logging driver: dial tcp 127.0.0.1:1514: connection refused`**
- 原因：Harbor 的容器都用 syslog 日志驱动，发到 harbor-log 容器（1514 端口）。开机时它们比 harbor-log 先启动，Docker **不会重试**这种失败。这与升级无关，任何一次重启都会发生，但升级要重启好几次。
- 处理：加一个 `harbor-autostart.service`：等 1514 端口可用后，`docker start` 该 compose 项目里已经退出的容器（见 app-compat.md 的 Harbor 一节）。

**★ 自编译 nginx 静态重编时的坑**（`nginx-static-build.sh` 已修）
- 正则误伤：`--with-openssl-opt=...` 被截成 `-opt=...`
- 老版本（如 1.16.x）的签名者公钥已不在 nginx.org/keys → 按 key ID 从 keyserver.ubuntu.com 获取
- 国内服务器下载 GitHub 上的 OpenSSL 超时 → 在本机下载后上传到 `/usr/local/src/nginx-static/`；残缺文件会被 sha256 校验发现并删除
- 运行中的二进制 `cp` 覆盖会报 `Text file busy` → 先复制再 `mv` 替换

**★ 卸载 `mysql-community-libs-compat` 会连带删掉 postfix**
- 原因：它替换了 `mariadb-libs` 提供的 libmysqlclient.so.18，postfix 依赖它。
- 处理：`yum swap -- remove mysql-community-* -- install mariadb-libs`（`prep-el7.sh inhibitors` 已做）；宿主机若装了 mysql-community-server 则不要自动处理。

## 2b. 源系统是 CentOS Linux 8 / Stream 8

**★ 资产表写的是"CentOS 7"，实际上是 CentOS 8.3**
- 处理：一律以 `survey.sh` 的结果为准。CentOS 8 要先 `convert-el8.sh` 转成 AlmaLinux 8，ELevate 只接受 AlmaLinux/Rocky/RHEL 8 作为 8→9 的源。

**★ `almalinux-deploy`：`Please upgrade your OS from 8.3 to … ERROR`**
- 原因：要求 ≥ 8.4。
- **不要用它的 `-f`**：`-f` 只认 `CentOS-Linux-BaseOS.repo` 这类原始文件名（否则报 `Error: No repo file found for BaseOS`），并会把源改到海外的 rackspace vault。
- 处理：`convert-el8.sh update`，用自己配好的国内 vault 源 `dnf upgrade` 到 8.5，再 `convert-el8.sh run`（默认 `-d`）。

**★ EL8 机器上配着 EPEL 7（`epel.repo` 里是 `epel/7`）**
- 风险：distro-sync / leapp 会从错误的大版本拉包。
- 处理：`convert-el8.sh prep` 会改成 EPEL 8。`survey.sh` 会对 EPEL 版本与系统不一致报 HIGH。

**★ 国内服务器访问不了 `raw.githubusercontent.com`**
- 处理：在本机下载 `almalinux-deploy.sh` 后用 `remote.py put` 上传。`-l=<MIRROR>/almalinux` 让它走国内镜像（阿里云内网 `mirrors.cloud.aliyuncs.com` 实测 66ms）。

**★ CentOS 8 的 repo 指向已下线的 `centos/8-stream`**
- 处理：改成 vault：CentOS Linux 8 用 `centos-vault/8.5.2111`，Stream 用 `centos-vault/8-stream`。

**★ almalinux-deploy 显示"Migration to AlmaLinux is completed"，但 680 个包还是 CentOS 的，内核也还是 CentOS 的**
- 现象：`distro-sync OK`，但 `rpm -qa --qf '%{VENDOR}\n' | sort | uniq -c` 里几乎全是 CentOS；`dnf upgrade` 显示 Nothing to do；日志里有 `Repository baseos is listed more than once`。
- 原因：自己写的 vault 源用了 `[baseos]/[appstream]/[extras]`，与 AlmaLinux 的 repo id 冲突，dnf 选用了 CentOS 的定义，distro-sync 实际同步回了 CentOS 8.5。vault 源不属于任何 rpm，almalinux-deploy 不会删除它。
- 处理：vault 源的 repo id 用不会冲突的名字（`c8vault-*`），并在执行 deploy 前移走（`convert-el8.sh` 已修）。已经中招的话：移走 vault 源 → `dnf -y distro-sync --allowerasing` → 确认 `grubby --default-kernel` 是 AlmaLinux 内核 → 重启。
- 判断标准：转换后 CentOS 厂商的包应只剩个位数（旧内核）。AlmaLinux 8 早期的包 vendor 显示为 **CloudLinux**，这是正常的。

**★ Aliyun 镜像里的 cloud-init 是源码安装的（`rpm -q cloud-init` 显示未安装，但 unit 是启用状态）**（3 台阿里云机器都遇到了；`hop.sh post` 现在会自动禁用并挪走这些不属于 rpm 的 unit）
- 现象：升到 EL9 后，cloud-init 的 4 个 unit 都变成 failed（它依赖 EL8 的 python3.6）。
- 处理：长期运行的 ECS 上，cloud-init 只在首次开机时有用。`touch /etc/cloud/cloud-init.disabled` 后执行 `systemctl reset-failed`。如果需要，就装发行版的 cloud-init 包。

## 3. 7 → 8

| 阻断项 / 报错 | 处理 |
|---|---|
| ★ `Leapp detected loaded kernel drivers which have been removed in RHEL 8`（floppy、pata_acpi） | `rmmod` + `/etc/modprobe.d` 黑名单（prep-el7.sh inhibitors） |
| ★ `Multiple devel kernels installed` | 只保留当前内核的 kernel-devel |
| ★ `Missing required answers`：`remove_pam_pkcs11_module_check.confirm` | `leapp answer --section remove_pam_pkcs11_module_check.confirm=True`（hop.sh answer） |
| ★ `Detected customized configuration for dynamic linker`（mysql-x86_64.conf） | 随 mysql-community-libs 一起换掉即消失 |
| ★ `dnf_transaction_check` 失败：`Failed to download metadata for repo 'el8-docker-ce-nightly'` | vendors.d/docker-ce.repo 改国内镜像并关掉 test/nightly 段（hop.sh prep） |
| ★ preupgrade 卡在 dnf_transaction_check 几十分钟 | EPEL 走 metalink 国外镜像，改国内 baseurl（hop.sh prep） |
| `Packages not signed by Red Hat`（hostguard、kubectl、自编译包…） | 不是阻断；但升级后这些包保持 EL7 版本，逐个确认还能用 |
| `Difference in Python versions` / `GRUB2 core will be updated` | 提示，无需处理 |
| /var 空间不足 | leapp 需要约 3~5GB；清 docker 无用镜像（先确认）、日志、yum 缓存 |

**★ 最严重：升级重启后进 initramfs 紧急模式，`upgrade.service failed`，日志 `dnf_upgrade_transaction ... python2-pyyaml install failed: cpio: File from package already exists as a directory`**
- 原因：pip 装的 PyYAML（`/usr/lib64/python2.7/site-packages/yaml`、`PyYAML-3.12-py2.7.egg-info`）和 rpm 冲突。只有这一个包失败，但 DNF 返回非 0 → leapp 后续阶段（清理、post 动作）全部没跑。系统其实已经大部分是 EL8 了。
- 处理：见 `recovery.md` 的"半升级"流程。预防：每跳前 pipfix。

## 4. 8 → 9

| 阻断项 / 报错 | 处理 |
|---|---|
| ★ `Cannot perform the VDO check of block devices` | `dnf install vdo`（让检查能跑），确认无 VDO 设备后 `leapp answer --section check_vdo.confirm=True`（hop.sh answer 自动） |
| ★ `Network configuration for unsupported device types detected`（ifcfg-eth0） | 老阿里云镜像的 ifcfg 没有 `TYPE=Ethernet`，且是静态 IP。EL8 的 NM（≥1.38）可以直接 `nmcli connection migrate` 转成 keyfile，`hop.sh answer` 在 8→9 遇到这个阻断项时自动处理（迁移前后对比地址和默认路由），也顺带解决了 9→10 的 ifcfg 阻断项 |
| ★ `iptables-services` 出现在 8→9 的删除列表 | EL9 改名为 `iptables-nft-services`。先看 `/etc/sysconfig/iptables`：如果只有全部 ACCEPT（常见），删了也没影响；如果有真实规则，升级后安装 iptables-nft-services 并 enable |
| ★ `Firewalld Configuration AllowZoneDrifting Is Unsupported` | `AllowZoneDrifting=no`（EL9 行为本来就等同于 no）；`hop.sh answer` 自动处理。**不要 `firewall-cmd --reload`**：可能清掉 Docker 的 iptables 链，导致容器网络断开，重启时自然生效 |
| ★ 安装 el8 的 leapp 时 `filtered out by exclude filtering` | 上一跳 leapp 在 /etc/dnf/dnf.conf、/etc/yum.conf 留了 `exclude=...leapp...`，删掉（hop.sh 已处理） |
| ★ 旧 el7 leapp 包残留导致 el8 leapp 装不上 | `rpm -e --nodeps` 删旧 leapp 包 + 删 /etc/leapp/files（hop.sh prep/post 已处理） |
| `Remote root logins globally allowed using password` | 若 sshd_config 显式写了 `PermitRootLogin yes` 则只是提示；**没写的话 EL9 默认 prohibit-password，root 密码登录会失联**，先显式写上 |
| python2 | EL9 没有 python2。确认无人依赖后移除（hop.sh prep 会检查依赖）；有依赖的脚本先改 python3 |
| ★ 宿主机 docker 容器正常但 Yearning 无限重启：`open /sys/fs/cgroup/memory/memory.limit_in_bytes: no such file` | EL9 起默认 cgroup v2。见 app-compat.md "cgroup v2" |

## 5. 9 → 10

| 阻断项 / 报错 | 处理 |
|---|---|
| ★ `Deprecated DHCP plugin configured` | NM 用的是 `dhcp=dhclient`，而 EL10 没有 dhclient。来源可能不在 /etc：实测在 `/usr/lib/NetworkManager/conf.d/10-dhcp-dhclient.conf`，是**不属于任何包的残留文件**。`hop.sh answer` 会注释掉 /etc 里的这一行，并挪走 /usr/lib 下的残留文件；用 `NetworkManager --print-config \| grep dhcp` 确认已不再生效。静态 IP 的网卡不受影响 |
| ★ `Legacy network configuration found`（每个 ifcfg 一条） | 先备份 network-scripts，`nmcli connection migrate`（不重连，地址/路由不变），确认 eth0 的 FILENAME 变成 .nmconnection |
| ★ `Berkeley DB (libdb) has been detected` | EL10 没有 libdb。postfix 的 `hash:` 表升级后改 `lmdb:`（finalize.sh postfix-lmdb）；其它用 libdb 的程序要换 |
| ★ `kernel drivers which are no longer maintained`（nft_compat、ip_set） | 提示；fail2ban/docker 仍可用，升级后验证 |
| CPU 不满足 x86-64-v3 | AlmaLinux 10 标准版无法启动！survey 会报 BLOCKER；用 x86_64_v2 变体或停在 9 |
| ★ 事务里会删掉 java-1.8.0/11/17-openjdk、redis、dhcp-client 等 | 用 `hop.sh report` 看"将被删除的包"：宿主机直接跑 Java 8/11/17 程序的要改用容器或自带 JDK；NetworkManager 配了 `dhcp=dhclient` 的要先改回 internal |

## 6. 每跳重启后

**★ `leapp_resume.service` failed：`ModuleNotFoundError: No module named 'leapp.libraries.common.rhsm'`**
- 原因：重启后 SSH 一恢复，就马上执行了清理（删除 leapp 包和 /etc/leapp），而 leapp 的 FirstBoot 阶段（`leapp_resume.service`，含 removeleftoverpackages 等）还在跑，被删掉了自己的模块。
- 处理：`hop.sh post` 现在会先等 `leapp_resume.service` 结束（最多 30 分钟）再清理；它失败时会打印日志并继续清理残留包和内核，最后删掉这个临时 unit。
- 教训：SSH 能连上 ≠ 升级流程已经结束。

**dbus.service 在 EL9 上"没有运行"** → 被 `dbus-broker.service` 取代，属于预期（verify.sh 已映射）。
**sssd / smartd / vdo / rngd-wake-threshold "没有运行"** → 新版本 unit 带启动条件，没有配置就跳过（verify.sh 会识别 `ConditionResult=no`）。

**★ `Error: Cannot find a valid baseurl for repo: epel-cisco-openh264`**
- 原因：这个源只有 metalink（codecs.fedoraproject.org），镜像站没有它；改写镜像时把 metalink 注释掉了，导致没有任何可用地址。
- 处理：`hop.sh post` 改写镜像时跳过它并将其 `enabled=0`（极少需要 openh264）。

**★ 旧 repo 文件仍指向 EL7/EPEL7，`dnf distro-sync` 报一堆 "nothing provides … from epel"**
- 原因：用户改过的 repo 文件不会被覆盖，新版本放在 `*.rpmnew`；旧文件以 `*.rpmsave` 留下。
- 处理：`hop.sh post`：rpmnew 替换、rpmsave 挪走、硬编码旧版本号的源挪走、镜像改写。

**★ `dnf distro-sync` 报模块包冲突（javapackages、eclipse/maven 模块）**
- 处理：用 `dnf -y upgrade --nobest` 即可，不必强求 distro-sync。

**★ 7→8 后 EL7 内核删不掉：`%preun(kernel-3.10.0-…) scriptlet failed, exit status 127`**
- 原因：EL7 内核包的卸载脚本调用 `new-kernel-pkg`，EL8 上没有这个命令。
- 处理：`hop.sh post` 会用 `rpm -e --noscripts` 删除，再清理 `/boot` 下对应的文件、`/lib/modules/<ver>` 和 BLS 启动项。

**★ 7→8 预检又报 floppy/pata_acpi 已加载（明明已经加了黑名单）**
- 原因：黑名单只写在 /etc/modprobe.d，但开机用的是旧 initramfs（黑名单之前构建的），所以模块又被加载了。另外 `prep-el7.sh inhibitors` 曾把 "rmmod xxx" 写进了黑名单文件。
- 处理：两处都已修复：写入黑名单后用 `dracut -f` 重建 initramfs；`hop.sh answer`（7→8）会再卸载一次。

**★ 旧内核、leapp 包、/var/lib/leapp（3GB+）残留**
- 处理：`hop.sh post` 统一清理，并删失效的 BLS 启动项。

**★ cloud-init 服务 failed（203/EXEC）**
- 原因：EL7 上是 pip/egg 装的 py2 cloud-init。
- 处理：长期运行的机器上 cloud-init 作用有限，可 `touch /etc/cloud/cloud-init.disabled`；AWS 等依赖它的环境改装新系统 cloud-init 包（见 cloud-providers.md）。

**云厂商 SysV 插件**（华为 hostguard/ICAgent/CloudResetPwd…）：AlmaLinux 10.2 仍保留 systemd-sysv-generator，实测能正常启动；为防以后去掉，可 `finalize.sh sysv-units` 包成原生 unit。升级前就坏的插件（如 cloudResetPwdAgent）在报告里注明"非本次引起"。

## 7. 升级后应用层

**★ 自编译 nginx：`libssl.so.10: cannot open shared object file`**
- 处理：过渡期 `nginx-static-build.sh`（同版本静态 OpenSSL/PCRE，实测 EL8 上编译后在 EL9、EL10 都能跑）；最终换 nginx.org 官方包。

**★ `docker-compose up -d` 报 `KeyError: 'ContainerConfig'`，而且旧容器已被改名为 `<短id>_<名字>`**
- 原因：docker-compose v1.29 与 Docker ≥ 25 不兼容，失败前已经重命名了旧容器。
- 处理：`docker compose`（v2）重建；先 `docker rm` 那个改名后的残留容器（确认它没有数据卷！）；`finalize.sh compose-wrapper` 让 `docker-compose` 命令转发到 v2。

**★ 删掉"没用"的 PHP 后某站点从 200 变 404**
- 教训：组件和站点的对应关系要在删之前告诉用户（nginx -T 里哪些 server 用 fastcgi_pass）。由用户决定站点去留。

**`pkill`/`docker stop` 后 VPN 断开、无法登录**：见 recovery.md "失联"。

**★ ssmtp 在 7→8 被删除（EL8 没有这个包）**：如果 `/etc/ssmtp/ssmtp.conf` 里配了 `mailhub`，说明机器用它发过邮件，升级后可以改用 EPEL 的 `msmtp`（配置格式相近），并写进报告。

**★ LNMP 一键包的 `/home/wwwlogs` 是 777**：自己加的 logrotate 会因为 "parent directory has insecure permissions" 跳过，需要在配置里加 `su root root`。

**★ 证书即将过期**：迁移 nginx 时顺手 `openssl x509 -noout -enddate` 检查，写进报告。

**★ nginx/openresty 跑在容器里，基线漏掉了所有站点**
- 现象：宿主机 `pgrep nginx` 能看到 master 进程，但路径（如 `/usr/servers/nginx/sbin/nginx`）在宿主机上不存在；老版本 nginx（<1.9.2）也没有 `-T`。
- 处理：`state.sh` 会进入 nginx/openresty/tengine 容器读取 server_name；没有 `-T` 时读取容器挂载点和常见目录下的 `*.conf`。另外所有 TCP 端口都按 IP 探测一次，443 用 https。
