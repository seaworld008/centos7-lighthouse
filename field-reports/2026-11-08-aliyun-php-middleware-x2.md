---
date: 2026-11-08
cloud: aliyun
profile: "两台 PHP + 中间件测试机：自编译 nginx（vhost 40+）+ PHP 7.2 容器 + 20~28 个中间件容器 + 宿主机 tarball MySQL 5.7 + 达梦 DM8 + Kingbase/OceanBase 工具"
source_version: CentOS 7.6 / 7.9
target_version: AlmaLinux 10.2
result: success
duration_hours: 3.3
skill_version: 0.4.0
operator: agent
---

# 阿里云两台 PHP + 中间件测试机：CentOS 7 → AlmaLinux 10.2（并行）

## 1. 机器画像（脱敏）
- 硬件：阿里云 ECS，KVM，BIOS 启动，x86-64-v3 支持。A 机 8C/30G，B 机 4C/15G。
- 运行时间：A 机 **861 天**、B 机 **1529 天**没有重启过。
- 磁盘：系统盘 100G / 60G（剩余 37G / 18G），数据盘 LVM ext4 挂 /data（Docker data-root 在 /data）。
- 业务组件：
  - 两台都有：自编译 nginx 1.30.6（/usr/local/nginx，SysV 脚本，OpenSSL 3.5.9，只有 libpcre.so.1 是 EL7 依赖），A 机 vhost 约 40 个、B 机约 60 个。PHP 7.2 之前已经迁到容器（php72-fpm/php72-cli，host 网络；`/usr/bin/php` 是转发到容器的包装脚本，cron 里 100+ 条 `/usr/bin/php think ...`）。
  - A 机：28 个容器（RocketMQ 5 集群、Redis ×3、MySQL 8 / 5.7、RabbitMQ、Canal、Yearning、vector 等）；宿主机源码编译的 MySQL 5.7.26（tarball，SysV 启动）；达梦 DM8（dmserver 手工启动，另有 enabled 的 `DmServiceDMTEST.service`）；KingbaseES V9（开机自启，但许可证过期）；OceanBase `ob-deploy` 工具 rpm（集群没运行）；php72-cli 容器里 supervisor 管 52 个队列 worker。
  - B 机：27 个容器（RocketMQ、Redis ×6、MySQL 8 / 5.7、MariaDB Spider、EMQX、Flink、Canal、frps 等，大部分有内存限制）；rsyncd。
  - 同一 VPC 的 K8s 集群里有业务 pod 直接用这两台的 Redis / MySQL。
- 访问路径：VPC 内网 SSH（非 22 端口）。B 机的 frps 是给别人用的内网穿透，不是我们的访问路径。
- survey 摘要：BLOCKER 只有 pip 残留（42 个文件）和 frps（不涉及访问路径）；HIGH 包括自编译 nginx、mysql-community-libs、docker-compose v1、NetworkManager 没运行、多个 kernel-devel、floppy/pata_acpi、`restart=no` 的容器、手工启动的 dmserver。

## 2. 与业务方确认的决定
- 两台都做了快照；测试环境，允许多次中断。
- 用户要求：只升级系统，**达梦、OceanBase 工具、MySQL 保持原版本**，兼容新系统即可。
- 不删除任何组件。Kingbase / CDM 服务升级前就起不来，交给业务方。

## 3. 时间线（两台并行）
| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|
| 19:36 | 上传工具包、survey、backup | A 机基线里 0 个容器 → 发现 state.sh 不兼容 Docker 19.03，修复后补录 |
| 19:45 | prep-el7 | A 机 `yum update` 两次整体失败：MySQL 源 GPG、ob-deploy 文件冲突 |
| 19:58 | nginx 同版本静态重编（OpenSSL 3.5.9 + 静态 PCRE） | 两台都替换并重启，站点无变化 |
| 20:06 | 达梦改由自带的 systemd unit 管理 | 用官方脚本停掉手工进程，再 `systemctl start` |
| 20:10 | 切换 NetworkManager + **EL7 先重启一次** | 暴露 3 个升级前就有的问题（见 4.4） |
| 20:20 | 7→8 preupgrade | 两台 0 阻断 |
| 20:38 | 7→8 `leapp upgrade` | 两台都在 dnf_package_download 失败：Remi 兼容库文件冲突 |
| 20:50 | 删 Remi 库后重跑，重启 | 20:56 / 21:02 到 EL8.10；B 机 9 个站点 200→000（curl h2 误报） |
| 21:10 | 8→9 | 两台都被 SHA1 签名阻断：EL7 SCL 残留；A 机还有 ob-deploy |
| 21:31 | B 机到 EL9.8 | 0 FAIL；libxcrypt-compat 随升级装上，nginx 直接起来 |
| 21:53 | B 机到 EL10.2 | 0 FAIL |
| 22:03 | A 机到 EL9.8 | ob-deploy 只从 rpm 库移除（文件保留），0 FAIL |
| 22:35 | A 机到 EL10.2 | 0 FAIL |
| 22:40 | 收尾 | compose v2 包装；A 机装 mysql8.4 客户端（备份脚本验证可用）、ncurses-compat-libs（MySQL 5.7 自带的 mysql 客户端） |
| 22:45 | 最终重启自启测试 | 两台全部自己起来，0 FAIL |
| 22:50 | 检查 K8s 集群 | 7 个依赖 A 机 Redis/MySQL 的 pod 在 A 机重启期间 CrashLoop，A 机稳定后自己恢复；观察 5 分钟无新增重启 |

## 4. 遇到的问题

### 4.1 Docker 19.03 上基线没有记录任何容器
- 阶段：备份
- 现象：baseline.tsv 里 `ctr` 行为 0，而机器上有 28 个容器。
- 原因：`docker ps --format '{{.State}}'` 是 Docker 20.10 才有的字段，19.03 报模板错误、不输出。
- 处理：`state.sh` 失败时改用 `{{.Status}}` 推出 running/exited 等状态；补录基线。
- 状态：promoted → `state.sh`、`pitfalls.md` §6

### 4.2 `yum update` 整个事务失败（第三方源）
- 阶段：EL7 准备
- 现象：① `mysql-community-client-8.0.46 ... GPG Keys ... are not correct for this package`；② `file /usr/obd/plugins/oceanbase-ce-libs from install of ob-deploy-4.7.0 conflicts with file from package ob-deploy-2.10.1`。
- 处理：mysql-community-* swap 成 mariadb-libs（客户端到 EL10 装发行版 mysql8.4）；OceanBase 源挪走。
- 状态：promoted → `pitfalls.md` §2

### 4.3 nginx 已是 OpenSSL 3.5.9 编译的
- 阶段：EL7 准备
- 现象：只有 libpcre.so.1 是 EL7 依赖；脚本默认会用 OpenSSL 1.1.1w 重编，等于降级。
- 处理：`nginx-static-build.sh` 新增 `NGX_OPENSSL`/`NGX_OPENSSL_SHA256`，用 3.5.9 + 静态 PCRE 8.45 重编（EL7 gcc 4.8.5 可编）。重编后仍依赖 libcrypt.so.1（见 4.7）。
- 状态：promoted → `nginx-static-build.sh`、`pitfalls.md` §2

### 4.4 长期不重启：EL7 上先重启一次暴露的问题
- 阶段：EL7 准备
- 现象：① B 机 node_exporter `restart=no`，重启后没起来；② A 机 KingbaseES 开机自启失败 `License file expired`；③ A 机 CDM 实例服务失败；④ cloud-init（pip 装的 py2 版本）在 pipfix 后失败。
- 处理：① `docker update --restart=always`；②③ 升级前就起不来，报告给业务方；④ 禁用。
- 预防：运行很久的机器先在 EL7 重启一次，把"本来就有的问题"和升级问题分开。
- 状态：promoted → `pitfalls.md` §2

### 4.5 7→8 下载阶段失败：Remi 兼容库文件冲突
- 阶段：7→8
- 现象：preupgrade 0 阻断，`leapp upgrade` 报 `dnf_package_download ... Transaction test error: file /usr/lib64/libwebp.so.7 from install of libwebp-1.0.0-11.el8_10 conflicts with file from package libwebp7-1.0.3-2.el7.remi`（还有 libzip5）。
- 原因：宿主机 PHP 早已容器化，留下的 Remi 库（libwebp7/libzip5/libicu69/libicu72/oniguruma5php/gd3php/ImageMagick6-libs）没人用，但和 EL8 的同名 so 冲突。
- 处理：确认只有它们之间互相依赖后删除，重跑 `hop.sh up`。
- 状态：promoted → `prep-el7.sh inhibitors` 第 5 步、`survey.sh`（MEDIUM）、`pitfalls.md` §3

### 4.6 7→8 后 verify 误报 9 个 HTTPS 站点 200 → 000
- 阶段：7→8 之后
- 原因：EL8 的 curl 默认协商 HTTP/2，nghttp2 遇到非法响应头 `Access-Control-Allow-Credentials:`（头名带冒号）直接 PROTOCOL_ERROR；EL7 的 curl 不走 h2。nginx 和站点本身没有变化，`--http1.1` 返回 200。
- 处理：`state.sh` 探测固定 `--http1.1`；有问题的 vhost 列给业务方（严格的 HTTP/2 客户端访问这些站点会失败，升级前就如此）。
- 状态：promoted → `state.sh`、`survey.sh`（INFO）、`pitfalls.md` §6

### 4.7 EL9 起 libcrypt.so.1 缺失
- 阶段：8→9 之前（预防）
- 原因：EL9 的 libxcrypt 只提供 libcrypt.so.2，so.1 在 libxcrypt-compat 里且默认不装；静态重编的 nginx 和源码编译的 mysqld 5.7 都依赖它。
- 处理：`hop.sh prep` 扫描运行中的非 rpm 程序，需要时把 libxcrypt-compat 写进 `/etc/leapp/transaction/to_install`。两台到 EL9、EL10 后 nginx/mysqld 都直接起来。
- 状态：promoted → `hop.sh prep`、`survey.sh`（INFO）、`pitfalls.md` §4

### 4.8 8→9 阻断：`Detected RPMs with RSA/SHA1 signature`
- 阶段：8→9
- 现象：EL7 的 SCL 包（rh-ruby23-*、rh-php72-*、devtoolset-7/8、llvm-toolset-7）7→8 时原样留下；A 机还有 OceanBase 的 `ob-deploy`。
- 处理：SCL 没有进程/脚本使用，删除。ob-deploy 按用户要求保留：存文件清单、备份 rpm 库，`rpm -e --justdb --nodeps`（文件不动，`obd --version` 在 EL10 上仍是 2.10.1）。EL9 后删除 SHA1 的 gpg-pubkey，消掉每次 rpm 操作的警告。
- 状态：promoted → `hop.sh post`（自动删 SCL）、`pitfalls.md` §4

### 4.9 MySQL 客户端
- 阶段：收尾
- 现象：① 备份 cron 用 `/usr/bin/mysqldump`（原来是 mysql-community-client 8.0.36，EL10 没有 8.0 的包）；② MySQL 5.7.26 自带的 `mysql` 客户端缺 libncurses.so.5。
- 处理：① 装发行版 mysql8.4，按备份脚本自己的写法（`-p$PASSWORD`）连 5.7 实例验证 `SHOW DATABASES` 和 `mysqldump` 正常。注意 8.4 客户端**不再读 `MYSQL_PWD` 环境变量**，用它测试会误以为密码错误；② 装 EPEL 的 ncurses-compat-libs。
- 状态：本报告（app-compat 层面的细节）

### 4.10 K8s 集群 pod 重启
- 阶段：收尾
- 现象：两个测试命名空间里 7 个 pod CrashLoopBackOff 或不 Ready：`Unable to connect to Redis server: <A机>:6383`、`Communications link failure`（MySQL）。
- 原因：A 机每跳重启时中间件不可用，Spring 应用启动失败退出；A 机最后一次重启（22:45）后，pod 在下一次退避重试时自己恢复。
- 处理：确认 A/B 机中间件端口都可达；观察 5 分钟无新增重启、日志无连接错误。
- 预防：升级依赖方的中间件机器前告诉 K8s 业务方，或升级完统一 `kubectl rollout restart`。

## 5. 结果对比（verify.sh，最终重启后）
| 检查项 | 升级前 | 升级后 | 备注 |
|---|---|---|---|
| 系统 | CentOS 7.6 / 7.9 | AlmaLinux 10.2，kernel 6.12 | |
| Docker | 19.03 / 20.10，cgroup v1 | 29.9.3，cgroup v2 | Yearning 3.1.9、RocketMQ、Flink、Canal 等 Java 容器正常 |
| 容器 | A 28 个 / B 27 个 | 全部同状态 | |
| 端口 | A 35 个 / B 47 个 | 全部在监听 | udp/68 消失（dhclient → NM 内置 DHCP） |
| 站点 | 每个 vhost 的 HTTP 码 | 与升级前相同 | |
| nginx | 1.30.6 / OpenSSL 3.5.9 | 同版本（静态 PCRE） | |
| MySQL（宿主机） | 5.7.26 | 5.7.26 | 依赖 libxcrypt-compat、ncurses-compat-libs |
| 达梦 | DM8 | 同版本 | 改由自带的 systemd unit 管理 |
| OceanBase 工具 | obd 2.10.1 | 2.10.1 | 只从 rpm 库移除 |
| PHP | 7.2.34 容器 | 不变 | supervisor 52 个 worker RUNNING |
| systemctl --failed | — | kingbased、CDMService | 升级前就起不来（许可证过期等） |

## 6. 技能/脚本的不足
- 本次修了 8 处：state.sh（Docker 19.03、h2 误报）、prep-el7.sh（Remi 库）、hop.sh（libxcrypt-compat、SCL）、nginx-static-build.sh（OpenSSL 3）、survey.sh（3 个新检查项）。
- 第三方源让 `yum update` 整个失败时，`prep-el7.sh update` 只打印了 Error Summary，没打印 `Transaction check error` 那几行，需要去看日志。

## 7. 遗留事项
- KingbaseES 许可证过期、CDM 实例服务失败（升级前就是这样）：由业务方决定续期或禁用开机自启。
- B 机 13 个 vhost（含 .bak 文件）的 `add_header` 头名带冒号，HTTP/2 客户端会失败：建议业务方去掉冒号。
- 宿主机 MySQL 客户端由 8.0.36（Oracle rpm）换成发行版 8.4.11（EL10 没有 8.0 的包；8.0 已停止维护），服务端 5.7.26 不变。
- SysV 脚本（nginx、mysql、kingbased）在 AlmaLinux 10.2 上仍由 systemd-sysv-generator 启动；为防以后去掉，可用 `finalize.sh sysv-units` 包成原生 unit。
- 备份位置：两台的 `/data/os-upgrade-backup/20261108-1941`；nginx 旧二进制 `/usr/local/nginx/sbin/nginx.bak-el7-20261108`。
