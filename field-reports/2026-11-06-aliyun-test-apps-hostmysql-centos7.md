---
date: 2026-11-06
cloud: aliyun
profile: test environment — 4 PHP app containers + php-apache + openresty + MySQL 8 / Redis ×3 containers + vector log shippers + host MySQL 5.7 (tarball install) + cron-driven docker exec jobs
source_version: CentOS Linux 7.9.2009 (uptime 736 days)
target_version: AlmaLinux 10.2
result: success
duration_hours: 1.9
skill_version: 0.3.0 + fixes in this run (CHANGELOG 0.3.1)
operator: agent
---

# 阿里云测试应用机：CentOS 7.9 → AlmaLinux 8.10 → 9.8 → 10.2

## 1. 机器画像（脱敏）
- KVM（Alibaba Cloud ECS），BIOS 启动，2 vCPU / 8G，CPU 支持 x86-64-v3；系统盘 100G ext4，数据盘 200G LVM xfs
- 容器 15 个（13 个 running，2 个本来就 exited 的一次性 vector backfill）：4 个 PHP 业务容器、php-apache、openresty、MySQL 8、Redis ×3、vector ×2、fail2ban
- 宿主机：MySQL 5.7.42 **通用二进制 tarball** 安装（`/opt/mysql`，SysV 脚本 `mysqld`，监听 3306），cron 每天用 tarball 自带的 mysqldump 备份；约 20 条 cron 用 `docker exec ... php think ...` 驱动定时任务
- 宿主机装了 netbird rpm（服务 enabled，但连不上管理端，没有隧道接口，实际不工作），以及 zabbix、proxysql（未启用）等第三方 rpm
- 网络：network.service；survey 报 VPN BLOCKER → 核实后本机**不是** VPC 路由节点（路由节点是另一台），所以对访问路径没有影响
- 已连续运行 736 天

## 2. 与业务方确认的决定
- 快照和备份已做，可以重启，全部由 agent 执行；不下线任何组件

## 3. 时间线
| 阶段 | 结果 |
|---|---|
| 勘察 / 备份 / 基线 | 13 个容器、12 个域名（其中 1 个 https 升级前就是 502） |
| `prep-el7.sh repos` | **卡在 `yum repolist` 20 分钟**（见 4.1）→ 改为 curl 探测后 33 秒完成 |
| update / pipfix / inhibitors / netmgr | 顺利；NM 切换 SWITCH_OK |
| EL7 重启（进入新内核 + 验证 NM） | FAIL=0 |
| 7→8 | 0 阻断；mariadb-libs 会被删 → 确认备份脚本用的是 tarball 自带的 mysqldump；EL7 内核用新加的 `--noscripts` 逻辑删除成功 |
| 8→9 | 0 阻断；libxcrypt-compat 被装上（tarball MySQL 需要 libcrypt.so.1）；proxysql（未使用）被删 |
| 9→10 | `hop.sh answer` 自动处理了 /usr/lib 下残留的 dhcp=dhclient 和 ifcfg 迁移，0 阻断 |
| EL10 收尾 + 最终重启测试 | FAIL=0；唯一的 WARN 是 udp/68（dhclient 被 NM 内置 DHCP 取代，预期） |

## 4. 遇到的问题

### 4.1 `prep-el7.sh repos` 卡在 `yum repolist enabled`
- 原因：netbird 的 yum 源访问不了，yum 长时间重试
- 处理：改为对每个启用的源用 `curl -m 15` 探测 repomd.xml（或 mirrorlist），不通就 `enabled=0`；同时挪走所有 `CentOS-*.repo`；最后的 repolist 加了 300 秒超时
- 状态：promoted → `prep-el7.sh`、`pitfalls.md` §2

### 4.2 源码安装的 cloud-init unit 每跳之后都 failed（第三台阿里云机器了）
- 状态：promoted → `hop.sh post` 自动禁用并挪走这些不属于 rpm 的 unit

### 4.3 survey 的 VPN BLOCKER 需要人工核实
- 本机 netbird 服务是启用的，但实际不工作。对照本机 NetBird 客户端的路由表（哪个 peer 发布了 172.18.x/24）确认路由节点在别处。建议以后 survey 能区分"VPN 客户端在跑"和"本机是路由节点"（not yet）

### 4.4 其它
- `prep-el7.sh inhibitors` 先给所有旧内核重建 initramfs 再删除旧内核，白白浪费时间 → 调整了顺序（promoted）
- 宿主机 tarball 版 MySQL 5.7 的依赖（libaio、libnuma、libcrypt.so.1、libstdc++）在 EL8/9/10 都有，三跳之后都能运行，不用任何处理
- 残留的第三方 / 工具包（zabbix-release、htop、iftop、GeoIP 等 el7/el8 包）不影响运行，留着

## 5. 结果对比（verify.sh，最终重启测试后）
| 检查项 | 升级前 | 升级后 |
|---|---|---|
| 13 个运行中的容器 | running | running（开机自动拉起） |
| 12 个域名 + 各端口 | 基线 | 一致（eamapp 的 https 502 是升级前就有的） |
| 宿主机 MySQL 5.7.42（3306） | 运行 | 运行；mysqldump 可用 |
| cron 里的 docker exec php 任务 | 正常 | 正常（容器里 php 7.2 可用） |
| Docker / compose | 旧版 / v1 1.29.2 | 29.9.3 / v2（包装） |
| OpenSSH / OpenSSL | 7.4 / 1.0.2 | 9.9 / 3.5 |
| 待更新包 | — | 0 |

## 6. 技能/脚本的不足
- survey 对 VPN 的判断太粗（见 4.3）
- 宿主机 MySQL 的 SysV 脚本在 EL10 上靠 systemd-sysv-generator 启动，将来可用 `finalize.sh sysv-units` 包装成原生 unit

## 7. 遗留事项
- 本机 netbird 客户端长期连不上管理端（升级前就如此），是否还需要由业务方决定
