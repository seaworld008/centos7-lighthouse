---
date: 2026-11-12
cloud: huawei
profile: 三台生产机并行：PHP 站点容器 + 容器 MySQL + frps / 纯容器 + NFS 业务目录 / App 后台 + 每分钟直播 cron + supervisor 队列
source_version: CentOS 7.7 / 7.9 / 7.7
target_version: AlmaLinux 10.2（1 台）；AlmaLinux 9.8（2 台 c9，10 失败后退回）
result: partial
duration_hours: 4.8
skill_version: 0.5.0
operator: agent+human
---

# 华为云三台生产机并行升级：一台到 10.2，两台 c9 卡在 EL10 升级 initramfs，换盘退回 9.8

## 1. 机器画像（脱敏）
| | A（10.0.0.190） | B（10.0.0.29） | C（10.0.0.185） |
|---|---|---|---|
| 规格 | **c9**.xlarge.2，4C/8G，系统盘 300G | **c9**.xlarge.2，4C/8G，系统盘 150G（SCSI） | **s3**.xlarge.2，4C/8G，系统盘 200G + 数据盘 400G |
| 系统 | CentOS 7.7 | CentOS 7.9 | CentOS 7.7（连续运行 566 天） |
| 业务 | 十几个 PHP/静态站：nginx、php-fpm/cli 7.2、fail2ban、MySQL 5.7、vector 全部容器化；宿主机 frps（三所学校的闸机/门禁/叫号机隧道）、rsyncd；27 个 supervisor 队列在 php-cli 容器里；23 条 cron | 纯容器：业务 ×8（4+4 副本）、nginx、fail2ban、redis，全部 restart=always；**业务上传/日志目录是另一台机器的 NFS**；7 条 `docker exec` cron | App 后台（ThinkPHP）：nginx、php 7.2 容器；**约 100 条 cron（其中 ~15 条每分钟的直播自动化）**，经 `/usr/bin/php` 包装脚本进容器；**54 个 supervisor 队列进程**；vector 日志采集 |
| 特殊点 | Docker 被手工换成 29.x 静态二进制（rpm 库记着 19.03）；`/usr/sbin/nginx` 是转发到容器的包装脚本；39 个 pip 文件；Remi/SCL/webtatic 残留；pip 装的 cloud-init | Docker 19.03 rpm | Docker 同 A；宿主机 rpm 版 MySQL 5.7 **实际没在用**；mod_php72w、webtatic、Remi；mysql-community-libs 替换了 mariadb-libs；华为 DBSS 审计 agent（升级前就一直认证失败） |
| 访问 | 经 VPN 路由机 NAT（所有 SSH 来源 IP 相同） | 同左 | 同左 |
- x86-64-v3：三台都满足。survey 的 HIGH：pip 文件、Remi 残留、NFS、Docker 二进制与 rpm 记录不一致。

## 2. 与业务方确认的决定
- 快照：三台全部做了（C 的系统盘和数据盘都做）；晚上 20:30 开始，三台并发推进。
- A/C 的 Docker：保留手工替换的 29.x，只删 rpm 记录（`rpm -e --justdb --nodeps docker-ce docker-ce-cli containerd.io`，先把 unit 复制到 /etc/systemd/system 并 reenable）；A 的 nginx rpm 同样只删记录。
- C 的宿主机 MySQL：停用并卸载 server/client（数据目录原样保留并冷备份），libs 换回 mariadb-libs。
- A 的 frps：改为规范的 systemd 管理并开机自启（去掉对 docker 的启动依赖，启动前 `frps verify`，旧的 `start_frp.sh` 停用，readme 改成 systemctl 用法）。
- 两台 c9 在 9→10 失败后，用户决定：先退回 EL9 恢复业务；10 不行就留在 9（"不要再用 CentOS 7 就行"）。

## 3. 时间线
| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|
| 20:32 | 上传工具包、backup.sh + 额外备份（docker 二进制/unit、容器 inspect、MySQL 全库 dump、frps、NFS 挂载状态、supervisor/cron 清单） | 三台约 3~6 分钟 |
| 20:36~21:00 | EL7 准备：A/C 删 rpm 记录、卸载无用包；prep-el7 repos/update/pipfix/inhibitors/netmgr；EL7 重启测试 | 全部通过；B 的 compose-wrapper 踩坑（4.6） |
| 21:00~22:40 | 7→8：B 的 pam_tally2 与 NFS 阻断（4.4、4.5）；下载时三台各 250~350KB/s（4.8）；重启 | A 5 分钟、B 4 分钟、C 9 分钟起来；B 的 docker 抢在 NFS 前启动（4.3） |
| 22:40~23:25 | 8→9：下载 2 分钟；B 用 mask 锁住 docker；EL9 后 SSH 被 PerSourcePenalties 锁（4.7） | 三台到 9.8，业务正常 |
| 23:25 | A、B 重启进 9→10 | **两台都卡在升级 initramfs**（4.1） |
| 23:51 | C 重启进 9→10 | 00:02 到 10.2，业务正常 |
| 00:00~00:37 | 抢 GRUB 菜单多次失败；A 卸系统盘挂到同可用区的另一台机器、改 grubenv | A 回到 9.8，业务恢复（停机约 1 小时 10 分） |
| 00:40~01:00 | B 所在可用区没有其它机器：新建按需计费救援机，user data 自动改 grubenv（4.2） | B 回到 9.8，先挂 NFS 再启动 docker（停机约 1.5 小时） |
| 01:00~01:15 | C 的 vector 无限 OOM（4.9）；A 的 frps 规范化、B 的 docker 依赖 NFS；三台最终重启测试 | 全部 FAIL=0（B 只有随机 RPC 端口） |

## 4. 遇到的问题

### 4.1 ★★ 华为云 c9：EL10 内核在升级 initramfs 里探测 ata_piix 挂死
- 阶段：9→10 重启
- 现象：SSH 不回来。VNC：约 369 秒 hung task，`init_module_from_file → do_init_module → async_synchronize_cookie_domain`；之后 `dracut-initqueue: Timed out while waiting for udev queue to empty` 无限循环。Ctrl+Alt+Del 后关机日志：`systemd-udevd: 0000:00:01.1: Worker ... is taking a long time`（还有 virtio、VGA、cpu 的 worker 在等），SIGKILL 杀不掉，关不了机。
- 原因：0000:00:01.1 是模拟的 PIIX3 IDE（8086:7010，ata_piix）。EL10 的 6.12 内核在 c9（擎天）虚拟硬件上探测它时挂死；EL9 内核在同一台机器上正常；同晚的 s3 规格（同样有 PIIX3）9→10 正常。卡在挂根分区之前，系统盘没被改动。
- 处理：换盘改 grubenv 退回 EL9（4.2）。
- 预防：survey.sh 对华为云 c9 规格报 HIGH（从元数据 `metering.resourcespeccode` 取规格）；c9 只升到 9。次日对照实验证明与数据盘无关、黑名单 ata_piix 无效（见 4.11），"ata_piix 挂死"只是最初的猜测。
- 状态：promoted → `pitfalls.md` 9→10、`cloud-providers.md` 华为云、`SKILL.md`、`survey.sh`

### 4.2 ★ 抢不到 GRUB：leapp 升级项是持久默认项，换盘改 grubenv
- 现象：强制重启后又进升级环境；VNC 在强制重启后要几秒才重连（且同一 URL 不刷新，要先跳到别的 hash 再回来），5 秒的 GRUB 菜单一次都没抢到。
- 处理：强制关机 → 卸系统盘 → 挂到同可用区的救援机 → `grub2-editenv <boot>/grub2/grubenv set saved_entry=<EL9 内核的 BLS id>` → 挂回作系统盘 → 开机。A 用已有的同 AZ 机器（热挂，ext4 无 UUID 冲突）；B 所在 AZ 没有其它机器，新建按需计费救援机，**登录方式选"创建后设置"、把脚本放进 user data**，挂盘后脚本自动修改并在 VNC 打印结果，全程不需要密码。华为云 EVS 列表页把 SCSI 盘挂成系统盘时反复报"未挂载系统盘"，改用 ECS 详情页 → 磁盘 → 挂载磁盘 才成功。
- 状态：promoted → `recovery.md` F、新脚本 `scripts/rescue-grubenv.sh`

### 4.3 ★ `systemctl disable docker` 没挡住：容器在 NFS 恢复前启动
- 阶段：7→8 重启后
- 现象：B 重启后 docker 已经在跑，8 个业务容器把空的本地目录绑成了上传/日志目录；一个容器因为挂载的 supervisord.conf 不存在而退出（127）。
- 原因：升级事务里 docker-ce 被升级，包脚本重新 enable 了 docker。
- 处理：挂上 NFS 后 `docker restart` 这 8 个容器；`mount --bind / /mnt/x` 检查被盖住的本地目录，只有 3 个 nginx 日志文件，无上传数据丢失。之后两跳改用 `systemctl mask docker.service docker.socket`，重启后先挂 NFS 再 unmask/启动，均正常；最后加 drop-in `RequiresMountsFor=/data/<nfs 目录>`。
- 状态：promoted → `pitfalls.md` 每跳重启后、`hop.sh reboot`（自动 mask）、`k8s.sh nfs-on`（挂好后 unmask/启动）

### 4.4 ★ NFS 阻断项不必停业务：宿主机卸载，容器里的挂载照常
- 阶段：7→8 预检
- 现象：`Use of NFS detected`（fstab + 当前挂载）。
- 处理：注释 fstab 的 NFS 后在宿主机 `umount`（直接成功）；容器的 bind mount 在自己的挂载命名空间里，读写照常（实测写入正常），leapp 检查通过，下载期间业务不受影响。
- 状态：promoted → `pitfalls.md` 7→8

### 4.5 ★ pam_tally2 阻断，但配置在没人引用的 `-ac` 文件里
- 处理：`grep -l auth-ac /etc/pam.d/*` 无结果，system-auth/password-auth 是独立文件；注释 `-ac` 里的两行，登录行为不变。
- 状态：promoted → `pitfalls.md` 7→8

### 4.6 ★ finalize.sh compose-wrapper 在 EL7 上把 docker-compose 弄坏
- 现象：EL7 准备阶段跑了 compose-wrapper，Docker 19.03 没有 compose v2 插件，`docker-compose` 变成 `'compose' is not a docker command`。
- 处理：从备份恢复 v1；脚本改为先确认 `docker compose version` 可用，否则保留原文件并退出。冒烟测试已覆盖。
- 状态：promoted → `finalize.sh`、`tests/container-smoke.sh`

### 4.7 ★ EL9.8/EL10 的 OpenSSH 9.9 PerSourcePenalties 把我们锁在外面
- 现象：B 升到 EL9 后 SSH 报 `Error reading SSH protocol banner`；原始 banner 是 `Not allowed at this time`，持续约 5 分钟。
- 原因：wait-ssh 反复探测端口（连上不认证就断）被记为 noauth 惩罚；所有 SSH 都经 VPN 路由机 NAT，是同一个源 IP。
- 处理：停止探测等解除，写 `PerSourcePenaltyExemptList <路由机 IP>`；C 在升 9 前预先放好这个文件（EL8 的 sshd 不读 sshd_config.d，不影响），升级后直接生效。
- 状态：promoted → `pitfalls.md` 通用、`hop.sh prep` 自动写入

### 4.8 下载慢：不是带宽，是镜像侧临时限速；代理反而更慢
- 现象：7→8 时三台从阿里云镜像各 250~350KB/s，linux-firmware（662MB）一个包就下 30 多分钟，leapp 日志长时间不动。
- 排查：同一时间单台 curl 测速 14~16MB/s；用户提供的代理（在 VPC 内另一台机器上跑 mihomo）转发只有约 380KB/s；8→9、9→10 的下载都只用了约 2 分钟。代理没用上，事后删除了代理容器、镜像和订阅文件。
- 状态：promoted → `pitfalls.md` 通用、`cloud-providers.md`

### 4.9 ★ vector 升级后 OOM 无限重启
- 现象：C 的 vector 容器 RestartCount 256，`journalctl -k`：`Memory cgroup out of memory: Killed process (vector)`。
- 原因：停机几小时积压日志，追赶时约需 0.9GiB，compose 里 `mem_limit: 512m`（A 上同一采集器给的是 2G，正常）。
- 处理：`docker update --memory 1536m --memory-swap 1536m` 立即生效，同步改 compose 文件和部署记录，之后 0 重启。
- 状态：promoted → `pitfalls.md` 应用层

### 4.11 ★ 次日对照实验：与数据盘无关；黑名单 ata_piix 无效
- 起因：用户注意到失败的两台都只有系统盘，而之前所有成功的机器都有数据盘——但失败的两台同时也是仅有的 c9，两个因素混在一起。
- 做法：北京四 AZ1 按需开两台 c9.xlarge.2（官方 AlmaLinux 9.4 镜像 → `dnf upgrade` 到 9.8，内核与生产相同），一台只有系统盘、一台加 20G 数据盘，其余完全一样；同一份工具包跑 9→10。设了定时删除，登录用 user data 写入的临时公钥，不设密码。
- 结果 1：**两台都以同样方式卡死**（约 246 秒 hung task，`modprobe/udev-worker → async_synchronize_cookie_domain`），带数据盘的那台卡住时连 vdb 都还没探测到 → 与数据盘无关。
- 结果 2：把单盘测试机的系统盘挂到救援机，给升级启动项加 `modprobe.blacklist=ata_piix,ata_generic rd.driver.blacklist=ata_piix,ata_generic`、写 `/etc/modprobe.d` 黑名单后重启：启动日志里不再出现 ata_piix 的 scsi host，但**仍然同样卡死** → ata_piix 不是原因（EL10 内核里它是模块 `CONFIG_ATA_PIIX=m`，黑名单确实生效）。
- 结论：c9 只升到 AlmaLinux 9；目前没有验证过的绕过办法。v0.6.0 文档里"探测 ata_piix 挂死"的说法已更正。
- 状态：promoted → `pitfalls.md` 9→10、`cloud-providers.md`、`SKILL.md`、`survey.sh`（c9 判断不再依赖 PIIX3）

### 4.10 其它（只留在报告里）
- 华为云开了敏感操作保护：强制关机/重启、删除云服务器都要短信验证码（约 15 分钟内免验证），需要用户在场。→ `cloud-providers.md`
- A 的 rc.local 里 `nginx` 和 `systemctl restart rsyncd` 改成 `systemctl enable rsyncd`；B 的 nfs-server 开着但没有 export，保持原样。
- C 的 DBSS 审计 agent 升级前就一直认证失败，EL10 上起不来（依赖 OpenSSL 1.0），留给用户决定重装或卸载。

## 5. 结果对比（verify.sh）
| 检查项 | 升级前 | 升级后 | 备注 |
|---|---|---|---|
| A 容器 / supervisor / frps 客户端 | 6 / 27 / 2 | 6 / 27 / 2 | EL9.8，FAIL=0 |
| B 容器 / NFS / 站点码 | 11 / 已挂 / 一致 | 11 / 已挂（容器内 3~4 个 NFS 挂载）/ 一致 | EL9.8；FAIL 只有 4 个随机 RPC 端口；8 个容器 unhealthy 升级前即如此 |
| C 容器 / supervisor / 每分钟 cron | 4 / 54 / 正常 | 4 / 54 / 正常 | EL10.2；FAIL 只有已停用的宿主机 MySQL 3306 |
| 最终重启测试 | — | 三台全部自动恢复 | frps 开机自启、docker 等 NFS、vector 0 重启 |

## 6. 技能/脚本的不足
- 没有提前识别 c9 的风险（现在 survey 会报）；没有"卡在升级 initramfs、抢不到 GRUB"的救援流程（现在有 recovery.md F + rescue-grubenv.sh）。
- NFS 主机的 docker 防抢跑原先只靠 disable（现在 hop.sh reboot 自动 mask、k8s.sh nfs-on 自动放开）。
- compose-wrapper 缺少前置检查（已修）。
- 并发多台时 wait-ssh 的端口探测会触发 OpenSSH 9.8+ 的惩罚（hop.sh prep 现在自动豁免来源 IP）。

## 7. 遗留事项
- A、B（c9）停在 AlmaLinux 9.8；如要上 10，先在同规格测试机验证 ata_piix 黑名单方案，再重新跑 9→10。升级启动项已删除。
- C 的 DBSS 审计 agent：由用户决定在 DBSS 控制台重装或卸载。
- C 的宿主机 MySQL 数据目录与冷备份保留，确认无用后可删除。
- C 的 vector 内存上限 1536m：追平后可按实际用量回调。
