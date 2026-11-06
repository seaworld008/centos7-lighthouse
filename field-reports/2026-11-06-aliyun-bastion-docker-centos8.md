---
date: 2026-11-06
cloud: aliyun
profile: bastion host (JumpServer, 11 containers incl. MariaDB/Redis) + openresty reverse proxy container + fail2ban, firewalld on
source_version: CentOS Linux 8.3.2011 (mixed with 8.5 packages; repos pointing at retired 8-stream mirrors; EPEL 7 configured on EL8)
target_version: AlmaLinux 10.2
result: success
duration_hours: 1.8
skill_version: 0.1.0 + fixes in this run (see CHANGELOG [Unreleased])
operator: agent
---

# 阿里云堡垒机：CentOS 8.3 → AlmaLinux 8.10 → 9.8 → 10.2（第一次全程用技能脚本）

## 1. 机器画像（脱敏）
- KVM（Alibaba Cloud ECS），BIOS 启动，4 vCPU / 8G，CPU 支持 x86-64-v3
- 系统盘 60G xfs（剩余 19G）；另有一块未分区、未使用的 60G 数据盘
- 业务：JumpServer v3.10.6（11 个容器，含 MariaDB、Redis，全部 `restart: always`），openresty 容器（80/443/8080，老版本 nginx，没有 `-T`，托管约 10 个站点），fail2ban 容器
- 宿主机：firewalld 开启，Docker 20.10（cgroupfs、cgroup v1），exim/openvpn（来自 EPEL，未运行），阿里云 agent（aegis / 云助手 / 云监控），categraf，源码安装的 cloud-init
- 访问路径：操作端 → NetBird → 另一台主机上的路由节点 → VPC（VPN 不在本机）
- 资产表里写的是 "CentOS 7"，**实际是 CentOS 8.3**
- survey.sh：pip 装的文件 ×1、kernel-devel ×3、ifcfg ×1

## 2. 与业务方确认的决定
- 系统盘快照：已做；当场停机（测试环境）；阿里云 VNC 备用，全程没用上
- 不删除任何组件

## 3. 时间线
| 阶段 | 结果 |
|---|---|
| 勘察 + 备份 + 基线 | 第一次基线漏掉了容器里的站点 → 改进 `state.sh` 后重新记录（11 个域名 + 7 个端口） |
| `convert-el8.sh prep` | vault 源 + EPEL 8，挪走 pip 文件，删除多余的 kernel-devel |
| `convert-el8.sh run` | ① 报错要求 ≥8.4 ② `-f` 报 `No repo file found for BaseOS` → 新增 `update`（经国内 vault 升到 8.5） |
| almalinux-deploy | 报告"完成"，但 **680 个包仍是 CentOS**（见 4.1）→ 修复后执行 distro-sync，重启进入 AlmaLinux 内核 |
| AlmaLinux 8.10 | verify：FAIL 0；sssd、rngd-wake-threshold 因启动条件不满足而跳过（预期） |
| 8→9 | 阻断：firewalld AllowZoneDrifting；`hop.sh pre` 调用自身时报 Permission denied；post 与 leapp_resume 竞争（见 4.3） |
| AlmaLinux 9.8 | verify：FAIL 0；cloud-init 失效（源码安装，依赖 py3.6）→ 禁用；epel-cisco-openh264 没有可用地址 |
| 9→10 | `hop.sh answer` 自动迁移 ifcfg；0 阻断；Docker 升到 29.9.3（cgroup v2） |
| AlmaLinux 10.2 + 最终重启测试 | verify：FAIL 0 / WARN 0；jms_magnus 开机时等 core 重启了 1 次，之后稳定 |

## 4. 遇到的问题

### 4.1 almalinux-deploy 报告完成，实际没换包（repo id 冲突）
- 现象：`Migration to AlmaLinux is completed`，但 `rpm -qa --qf '%{VENDOR}'` 里 680 个包仍是 CentOS，默认内核仍是 CentOS 的；日志显示 `Repository baseos is listed more than once`
- 原因：`convert-el8.sh prep` 写的 vault 源用了 `[baseos]/[appstream]/[extras]`，与 AlmaLinux 的 repo id 相同；这个文件不属于任何 rpm，deploy 不会删除它
- 处理：移走 vault 源 → `dnf -y distro-sync --allowerasing` → 默认内核变为 AlmaLinux 的 → 重启
- 预防：vault 源改用 `c8vault-*` 作为 repo id，`run` 前自动移走；`post` 如果 CentOS 包 > 20 个就报错退出
- 状态：promoted → `pitfalls.md` §2b、`convert-el8.sh`

### 4.2 almalinux-deploy 要求 ≥ 8.4，`-f` 不适合国内环境
- 现象：`Please upgrade your OS from 8.3 to … ERROR`；加 `-f` 后报 `Error: No repo file found for BaseOS`
- 原因：`-f` 只认原始文件名 `CentOS-Linux-BaseOS.repo`，并会把源改到海外的 rackspace vault
- 处理：新增 `convert-el8.sh update`，经国内 vault 用 `dnf upgrade` 升到 8.5
- 状态：promoted → `pitfalls.md` §2b、`convert-el8.sh`

### 4.3 `hop.sh post` 与 leapp FirstBoot（leapp_resume.service）竞争
- 现象：8→9 之后 `leapp_resume.service` failed：`ModuleNotFoundError: No module named 'leapp.libraries.common.rhsm'`
- 原因：SSH 一恢复就执行 post，删除了 leapp 包，而 leapp 正在跑 FirstBoot 阶段的 removeleftoverpackages
- 影响：本次有限（post 自己清理了残留包，SELinux 是关闭的）
- 预防：post 先等 leapp_resume 结束（9→10 时实测：等到 activating 结束后才清理）
- 状态：promoted → `pitfalls.md` §6、`hop.sh post`

### 4.4 基线漏掉了容器里的 nginx 站点
- 原因：nginx/openresty 在容器里运行，宿主机上没有这个路径；老版本 nginx 不支持 `-T`；state.sh 原来跳过了 80/443 的按 IP 探测
- 处理：state.sh 会进入容器读取 server_name（不支持 `-T` 时读取挂载目录里的 `*.conf`），所有端口都按 IP 探测
- 状态：promoted → `state.sh`、`pitfalls.md` §7

### 4.5 其它
- `hop.sh pre` 末尾 `"$0" report` → Permission denied（SFTP 上传的文件没有执行权限）→ 改为 `bash "$0"`（promoted）
- firewalld `AllowZoneDrifting` 阻断 8→9 → `hop.sh answer` 自动处理，不做 reload，以免清掉 Docker 的链（promoted）
- 厂商源探测：PES 可能为空（docker-ce），改为按 `.sigs` 签名 key 匹配（promoted）
- 资产表里写的是 CentOS 7，实际是 CentOS 8：一律以 survey 为准（promoted：survey 对 CentOS 8 报 BLOCKER）
- EL8 上配着 EPEL 7（promoted：survey 报 HIGH，convert-el8.sh prep 会修正）
- dbus → dbus-broker；sssd/smartd/vdo 因启动条件不满足而跳过 → verify.sh 视为预期（promoted）
- 源码安装的 cloud-init 在 EL9 失效 → 禁用（promoted：pitfalls、cloud-providers）
- epel-cisco-openh264 只有 metalink，镜像站没有 → 禁用（promoted：hop.sh post）
- 快照瞬间显示 running 的容器也可能在 crash-loop → verify.sh 增加 30 秒 RestartCount 检测（promoted）

## 5. 结果对比（verify.sh）
| 检查项 | 升级前 | 升级后 |
|---|---|---|
| 12 个容器 | running | running（最终重启后自动拉起；jms_magnus 开机时重启 1 次后稳定） |
| 11 个站点 https | 200 ×10、403 ×1 | 相同 |
| 11 个站点 http | 301 | 301 |
| 80 / 443 / 8080（按 IP） | 301 / 403 / 200 | 相同 |
| SSH、JumpServer SSH/DB/Redis 端口 | listening | listening |
| 阿里云 agent | aegis / 云助手 / 云监控 运行 | 运行（CmsGoAgent 升级前就未运行） |
| Docker | 20.10，cgroup v1 | 29.9.3，cgroup v2 |
| OpenSSH / OpenSSL | 8.0 / 1.1.1 | 9.9 / 3.5 |
| 待更新包 | — | 0 |

## 6. 技能/脚本的不足
- 本机是 CentOS 8，`prep-el7.sh` 和 `swap-openssh.sh` 没有用到，issue #5 仍需一台真正的 CentOS 7
- 本次由 agent 在执行中修复的问题已全部合入，下一台 CentOS 8 应能直接跑通

## 7. 遗留事项
- cloud-init 已禁用（源码安装版失效）；如需要请安装发行版的 cloud-init 包
- exim 被升级移除（升级前就未运行）；如需本机发信，请安装 postfix
