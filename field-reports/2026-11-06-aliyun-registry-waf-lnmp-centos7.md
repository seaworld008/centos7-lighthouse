---
date: 2026-11-06
cloud: aliyun
profile: image registry (Harbor 2.6, 95G on data disk) + API docs (YApi + MongoDB) + MySQL 5.7 container + WAF (SafeLine, host network) + self-built LNMP (nginx 1.16 / PHP 5.6) + stopped Confluence
source_version: CentOS Linux 7.6.1810
target_version: AlmaLinux 10.2
result: success
duration_hours: 3.5 (excluding a ~1h pause for the operator's quota)
skill_version: 0.2.0 + fixes in this run (CHANGELOG 0.3.0)
operator: agent
---

# 阿里云多业务机：CentOS 7.6 → 7.9 → AlmaLinux 8.10 → 9.8 → 10.2（第一台全程用脚本完成的 CentOS 7，#5）

## 1. 机器画像（脱敏）
- KVM（Alibaba Cloud ECS），BIOS 启动，2 vCPU / 8G，CPU 支持 x86-64-v3；系统盘 100G ext4，数据盘 300G LVM ext4（/data）
- 容器 19 个：Harbor 2.6（9 个，syslog 日志驱动发到 harbor-log:1514）、YApi + MongoDB、MySQL 5.7（`unless-stopped`）、SafeLine WAF（tengine 用 host 网络监听 80/443）、fail2ban
- 宿主机：LNMP 一键包（nginx 1.16.1 自编译、内置 OpenSSL 1.1.1d、动态链接 pcre；PHP 5.6 自编译，依赖 libssl.so.10/ICU 50/libnsl；MySQL 空库且未启用）、Confluence 8.5.2（1.5 个月前已停止，unit 为 failed）、阿里云 agent、categraf、ilogtail
- 196 个 pip 装进系统 site-packages 的 py2 包（Django 1.9、各云厂商 SDK、docker-compose 1.26 等），没有正在运行的程序在用
- 网络：用的是 `network.service`（NetworkManager 没运行），ifcfg-eth0 是静态 IP 且没有 `TYPE=`；NM 配置里有残留的 `dhcp=dhclient`
- 宿主机 nginx 与 SafeLine tengine **都用 `reuseport` 监听 80**：请求随机落到其中一个（基线中 `127.0.0.1:80` 在 200/403 之间跳）
- 访问路径：操作端 → NetBird → 另一台主机上的路由节点 → VPC

## 2. 与业务方确认的决定
- 快照已做；当场停机
- 宿主机 nginx 保留，并升级到最新稳定版、配置开机自启；**PHP 彻底删除**（先打包备份）；Confluence 保持现状；**SafeLine 不动**（因此重启时不提前停止任何容器）

## 3. 时间线
| 阶段 | 结果 |
|---|---|
| 勘察 / 备份 / 基线 | 识别出上述"僵尸"组件；SafeLine 与宿主机 nginx 共享 80 端口 |
| nginx 静态重编（1.16.1 + OpenSSL 1.1.1w + PCRE 8.45） | 修了 4 个脚本问题（见 4.4）后成功 |
| 删除 PHP | 备份 php-removed.tgz（54M）后删除 |
| prep-el7：repos / update（7.6→7.9）/ pipfix / inhibitors | 顺利 |
| `prep-el7.sh netmgr`（新增） | network.service → NetworkManager，SWITCH_OK |
| EL7 上重启一次（进入新内核 + 验证 NM） | **6 个 Harbor 容器没起来**（见 4.1）→ 加 harbor-autostart.service |
| 7→8 | 预检：floppy/pata_acpi 又被加载（见 4.2）；升级本身 0 错误，没有出现 initramfs 失败 |
| AlmaLinux 8.10 | EL7 内核删不掉（见 4.3） |
| 8→9 | 阻断：ifcfg 缺 `TYPE`（见 4.5）；iptables-services 会被删（规则只有全部 ACCEPT，无影响） |
| 9→10 | 阻断：`dhcp=dhclient`，来自 /usr/lib 下的残留文件（见 4.6） |
| EL10 收尾 | nginx.org 1.30.6（systemd、开机自启）、docker-compose 包装为 v2、logrotate、残留 cloud-init unit 清理；最终重启测试 FAIL=0 / WARN=0 |

## 4. 遇到的问题

### 4.1 Harbor 重启后 core/registry/nginx 等全部 exited
- 现象：`failed to initialize logging driver: dial tcp 127.0.0.1:1514: connection refused`，RestartCount=0
- 原因：syslog 日志驱动依赖的 harbor-log 还没起来；Docker 不会重试这类失败。与升级无关，但升级要重启 4 次以上，每次都会中招
- 处理：`harbor-autostart.service`：等 1514 端口可用后，`docker start` 该 compose 项目里已经退出的容器。之后 3 次重启都能自动恢复
- 状态：promoted → `pitfalls.md` §2、`app-compat.md`（Harbor）

### 4.2 黑名单没进 initramfs，floppy/pata_acpi 重启后又被加载；黑名单文件里还混进了 "rmmod" 行
- 状态：promoted → `prep-el7.sh inhibitors`（dracut 重建）、`hop.sh answer`（7→8 时卸载）

### 4.3 EL7 内核卸载脚本在 EL8 上 exit 127
- 处理：`rpm -e --noscripts`，再手工清理 /boot、/lib/modules、BLS 启动项
- 状态：promoted → `hop.sh post`

### 4.4 nginx 静态重编
- `--with-openssl-opt=...` 被正则截成 `-opt=...`；1.16.x 的签名公钥已不在 nginx.org/keys（改为从 keyserver.ubuntu.com 按 key ID 获取，指纹 B0F4…52F8）；服务器下载 GitHub 上的 OpenSSL 超时（改为本机下载后上传，sha256 不符就删除）；`--install` 被 `set --` 吃掉；运行中的二进制 `Text file busy`（改用 mv 替换）
- 状态：promoted → `nginx-static-build.sh`、`pitfalls.md`

### 4.5 8→9：`Network configuration for unsupported device types`（ifcfg-eth0）
- 原因：老镜像的 ifcfg 没有 `TYPE=Ethernet`
- 处理：EL8 的 NM 1.40 直接 `nmcli connection migrate`；地址和默认路由不变
- 状态：promoted → `hop.sh answer`（8→9 时检测到该阻断项就执行）、`survey.sh` MEDIUM

### 4.6 9→10：`Deprecated DHCP plugin configured`
- 原因：`/usr/lib/NetworkManager/conf.d/10-dhcp-dhclient.conf`，不属于任何包的残留文件（按 leapp 的提示只查 /etc 是找不到的）
- 状态：promoted → `hop.sh answer`、`survey.sh` HIGH

### 4.7 其它
- 厂商源识别：leapp 装的 docker-ce 没有签名，按 `.sigs` 匹配不到 → 改为"同名第三方包已安装"也算在用（promoted）
- ssmtp 在 7→8 被删除，原来配置了 mailhub → 报告里建议改用 msmtp（promoted）
- `/home/wwwlogs` 是 777，logrotate 需要 `su root root`（promoted）
- 源码安装的 cloud-init unit 不认 `cloud-init.disabled`，每跳之后都 failed → 挪走这些 unit 文件
- 本机 NetBird 客户端中途断开约 1 分钟，导致 SSH 中断；leapp 在 systemd-run 里跑，不受影响

## 5. 结果对比（verify.sh，最终重启测试后）
| 检查项 | 升级前 | 升级后 |
|---|---|---|
| 19 个容器 | running | running（开机自动拉起，Harbor 依赖 autostart unit） |
| YApi 站点 / 3000 / 9080 / 9443 / 27018 / 65443 | 与基线一致 | 一致 |
| 80（宿主机 nginx 与 SafeLine 共享） | 200/403 随机 | 200/403 随机（与升级前相同） |
| 宿主机 nginx | 1.16.1 自编译，SysV | 1.30.6（nginx.org），systemd，开机自启 |
| PHP 5.6 | 运行（只服务默认页） | 按决定删除 |
| Docker / compose | 24.0.6 / v1 1.29.2 | 29.9.3 / v2（docker-compose 包装） |
| OpenSSH / OpenSSL | 7.4 / 1.0.2 | 9.9 / 3.5 |
| 待更新包 / 残留旧版本包 | — | 0 / 0 |

## 6. 技能/脚本的不足
- 现在 `hop.sh reboot` 会停所有"有状态 + always"的容器，但业务方可能要求某些容器不能动 → 建议加 `--no-stop` 选项（本次是直接 `systemctl reboot`）
- 宿主机 nginx 与容器 nginx 用 reuseport 共享端口时，基线不稳定；可以考虑在 verify 里把这类端口的结果当作集合来比较

## 7. 遗留事项
- Confluence 8.5.2 仍是停止状态（升级前就如此，按决定没有动）
- 如需本机发信，安装 msmtp（原来用的 ssmtp 已被移除）
- `/nginx_status` 对外可访问（升级前就如此）；建议限制为只允许 127.0.0.1
