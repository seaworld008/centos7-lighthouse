---
date: 2026-11-10
cloud: aliyun
profile: "CI 构建机：宿主机 Jenkins（rpm + 手工替换的 war，JDK 8 tar 包，367 个任务，8 个 Node 版本）+ GitLab omnibus 容器 + 测试环境共享 nginx 网关容器 + verdaccio + rsync 推送"
source_version: CentOS 7.9
target_version: AlmaLinux 10.2
result: success
duration_hours: 2.3
skill_version: 0.4.0
operator: agent+human
---

# CI 构建机（Jenkins + GitLab 容器 + 共享网关）CentOS 7.9 → AlmaLinux 10.2

## 1. 机器画像（脱敏）
- 硬件 / 虚拟化 / 启动方式 / CPU x86-64-v3：阿里云 ECS，KVM，BIOS，4 vCPU / 30G，x86-64-v3 YES；已连续运行 412 天
- 磁盘布局：系统盘 250G（用 47%），数据盘 LVM 250G（用 66%，GitLab 数据 141G、每日备份 6.3G/份）
- 业务组件：
  - 宿主机 Jenkins：rpm 写的是 2.204.1，实际 war 是 **2.346.1**（手工替换），SysV 启动、root 运行、JDK 8u92 tar 包；JENKINS_HOME 40G、367 个任务、133 个插件、只有内置节点
  - 构建工具：NodeJS 插件 8 个版本（11.11 / 13.12 / 15.2 / 16.14 / 16.20 / 17.9 / 18.20 / 20.19）、Maven 3.6.3 + JDK 8u271（`/etc/profile`）、`/usr/bin/php` 是转发到 PHP 7.2 容器的包装脚本、composer
  - 容器：GitLab CE 17.6.2（compose）、共享 nginx 网关（反代测试环境 20 多个域名）、verdaccio、fail2ban（host 网络、iptables-nft）、node_exporter、gitlab-runner（0 个注册 runner）
  - 宿主机 rsyncd：48 个模块把 Jenkins workspace 提供给 3 台部署机拉取
  - 其它：mariadb-server 5.5（已停用）、wine、svnserve（已停用）、remi PHP 7.2 rpm、自编译 openssh 9.7、postfix（已失败 1 年多）
- 访问路径：内网 SSH（非标准端口），VPN 不在本机
- survey.sh：BLOCKER 3（自编译 openssh、111 个 pip 文件、宿主机 mariadb-server）；HIGH 5（kernel-devel ×5、network.service、unless-stopped 容器、docker-compose v1、floppy/pata_acpi）

## 2. 与业务方确认的决定
- 快照：是（系统盘 + 数据盘）；停机窗口：当晚 17:50 起
- 下线 / 删除：mariadb-server 5.5（冷备份数据目录后卸载）、wine 全家桶、svnserve 服务、remi PHP rpm（包装脚本保留）、avahi；gitlab-runner 容器停用保留
- Jenkins 本次**不升级版本**（保持 2.346.1 + JDK 8），另起变更
- 升级前在另一台已是 AlmaLinux 10.2 的机器上实测：Jenkins war + 3 个 JDK + 8 个 Node 版本 + node-sass 4.14.1 全部可用，才决定原地升级

## 3. 时间线
| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|
| 17:47 | backup.sh + 额外备份（Jenkins 配置/插件/war、php 包装、rsyncd、/usr/local/sbin） | backup.sh 打包 /root 太慢（.m2 17G + .npm 16G）→ 加排除后重跑；基线 HTTP 全 000 → 修 state.sh |
| 17:58 | 删除 remi PHP / wine / mariadb-server，停 avahi、svnserve、gitlab-runner | `/usr/bin/php` 随 php-cli 被删（预先已复制），链接回去 |
| 18:00 | prep-el7 repos + update，EL7 内重启测试（412 天首次） | 全部自启 |
| 18:07 | compose-wrapper → pipfix → inhibitors → netmgr → swap-openssh | 全部成功 |
| 18:11 | Jenkins 改原生 systemd unit（环境与 SysV 完全一致） | 21s 起来 |
| 18:30 | 7→8（1 个阻断：pam_pkcs11） | 18:37 进入 8.10 |
| 18:43 | verify：GitLab 502 | PostgreSQL 残留锁文件，18:54 修复；加 stop_grace_period |
| 18:47 | 发现 6 个 `#!/usr/bin/python` 运维脚本（含 GitLab 每日备份）失效 | 改 python3 并验证 |
| 19:00 | 8→9（ifcfg、VDO、SCL SHA1、jenkins rpm DSA/SHA1） | 19:19 进入 9.8，Docker 29.9.3 + cgroup v2 |
| 19:25 | 9→10（dhcp=dhclient） | 19:42 进入 10.2 |
| 19:44 | 收尾：postfix（IPv6 已禁用 → inet_protocols=ipv4）+ lmdb、.npmrc 加 sass 镜像、Chromium 依赖 | |
| 19:47 | 最终重启测试 | 全部自启，verify FAIL=0 |
| 19:52 | 构建验证（复制 workspace，不部署） | 4 个前端项目（Node 13+node-sass / 15.2 / 16.14 / 16.20+yarn）、Maven、docker build、rsync 拉取全部成功 |

## 4. 遇到的问题

### 4.1 基线里所有 HTTP 探测都是 000
- 阶段：EL7 准备
- 现象：backup.sh 生成的 baseline.tsv 里 49 条 http 全是 000，而 curl 手工访问是 200。
- 原因：`state.sh` 上个版本加了 `curl --http1.1`（解决 EL8+ h2 的误报），EL7 的 curl 7.29 不支持这个参数。
- 处理：先探测 curl 是否支持再加。
- 状态：promoted → `state.sh`、`pitfalls.md` §2

### 4.2 backup.sh 打包 /root 十几分钟
- 阶段：EL7 准备
- 原因：构建机 /root 有 .m2 17G、.npm 16G。
- 处理：默认排除构建缓存目录。
- 状态：promoted → `backup.sh`、`pitfalls.md` §2

### 4.3 卸载 remi php-cli 时 `/usr/bin/php`（包装脚本）一起被删
- 阶段：EL7 准备
- 原因：包装脚本覆盖的是 rpm 拥有的文件。
- 处理：事先复制到 /usr/local/bin，卸载后链接回 /usr/bin（Jenkins 的 PATH 不含 /usr/local/bin）。
- 状态：promoted → `survey.sh`（第三方 rpm 可执行文件被修改 → MEDIUM）、`pitfalls.md` §2

### 4.4 GitLab 一直 502：PostgreSQL 残留锁文件
- 阶段：7→8 post
- 现象：`FATAL: lock file ".s.PGSQL.5432.lock" already exists`、`Is another postmaster (PID 375)`，postgresql 每秒重启。
- 原因：`hop.sh post` 的 dnf 事务让 dockerd 重启，GitLab 容器 10 秒后被 SIGKILL；新容器里 PID 375 恰好是某个线程，PostgreSQL 认为另一个实例还活着。`hop.sh reboot` 的"有状态容器"名单也不含 gitlab（镜像名 gitlab-ce）。
- 处理：停 postgresql、挪走锁文件、启动（崩溃恢复 `redo is not required`）；compose 加 `stop_grace_period: 5m`。后两次 docker 重启 PostgreSQL 都是正常关闭。
- 状态：promoted → `hop.sh`（stop_stateful/start_stateful，post 里 dnf 前也执行，名单加 gitlab 等）、`survey.sh`（GitLab 无 stop_grace_period → MEDIUM）、`pitfalls.md` §6、`app-compat.md` GitLab

### 4.5 不带版本号的 python shebang 脚本失效
- 阶段：7→8 之后
- 现象：`jenkins-systemd-watch.service` 每分钟 203/EXEC；同目录的 GitLab 每日备份、磁盘巡检、nginx 日志轮转脚本都是 `#!/usr/bin/python`。
- 处理：语法检查兼容 python3 后改 shebang，跑 `--check-current` 验证；旧的 Jenkins PID 看门狗 timer 停用（原生 unit 的 Restart= 代替）。
- 状态：promoted → `survey.sh`（MEDIUM）、`pitfalls.md` §7

### 4.6 jenkins rpm 是 DSA/SHA1 签名（8→9 阻断）
- 阶段：8→9
- 处理：Jenkins 已用自己的 unit 运行，`rpm -e --justdb --noscripts --nodeps jenkins`，war 校验和不变。
- 状态：promoted → `pitfalls.md` §4、`app-compat.md` Jenkins、`survey.sh`（INFO）

### 4.7 root 的 known_hosts 里 GitLab ssh 主机密钥是旧的（升级前就如此）
- 现象：root 手工 `ssh -p 2222 git@<gitlab>` 报 Host key verification failed；GitLab 的 host key 文件自 2021 年未变，known_hosts 与升级前备份逐字节一致。Jenkins 的检出不依赖它（升级前当天的构建正常）。
- 状态：只是这一台的特例，留在报告；交给用户决定是否更新 known_hosts

## 5. 结果对比（verify.sh）
| 检查项 | 升级前 | 升级后 | 备注 |
|---|---|---|---|
| 系统 | CentOS 7.9 / 3.10 | AlmaLinux 10.2 / 6.12 | |
| 常驻服务 | 21 | 一致 | avahi 按决定停用；dbus → dbus-broker；lvmetad 不再存在 |
| 容器 | 7 running | 6 running + gitlab-runner 停用 | 按决定 |
| 站点/端口 HTTP 码 | 7×200 11×301 13×302 7×403 5×502 | 一致 | 5 个 502 升级前即如此（后端未运行） |
| Docker | 26.1.4 / cgroup v1 | 29.9.3 / cgroup v2 | |
| Jenkins | 2.346.1 / JDK 8u92 / SysV | 同版本 / systemd unit | 环境变量一致 |
| Node 18.20 / 20.19 | 宿主机跑不了（glibc 2.17） | 可用 | 升级的附带收益 |
| postfix | failed（1 年多） | active | inet_protocols=ipv4 |

## 6. 技能/脚本的不足
- `hop.sh post` 不保护容器；有状态容器名单漏了 GitLab（已修）
- `state.sh` 的 `--http1.1` 在 EL7 上回归（已修）
- survey 没有检查：python shebang、被手工替换的 rpm 文件、GitLab 停止超时、Jenkins rpm（已加）
- Jenkins / Node 多版本 / GitLab 容器在 app-compat 里没有章节（已加）

## 7. 遗留事项
- 用真实 Jenkins 任务各跑一次（会部署到测试环境，由用户触发）
- Jenkins 2.346.1 已停止维护：另起变更升级到最新 LTS + JDK 21（110 个插件有更新）
- GitLab 17.6.2 → 最新补丁版（有 5 个后台迁移在跑，升级前等完成）
- gitlab-runner 容器确认无人使用后删除
- root known_hosts 里 GitLab 的旧主机密钥（4.7）
