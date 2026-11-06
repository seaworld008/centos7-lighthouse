---
date: 2026-11-05
cloud: huawei
profile: jump host + docker workloads (java jobs, mysql, sharding proxy, sql audit ui) + vpn router container + self-built nginx
source_version: CentOS 7.7.1908
target_version: AlmaLinux 10.2
result: success
duration_hours: 5.5
skill_version: pre-0.1.0 (this run produced the skill)
operator: agent+human
---

# 华为云跳板机：CentOS 7.7 → AlmaLinux 10.2（首个金丝雀）

## 1. 机器画像（脱敏）
- KVM（OpenStack Nova），BIOS 启动，4 vCPU / 8G，CPU 支持 x86-64-v3
- 系统盘 40G（剩 ~9.8G，/var/lib/docker 在系统盘），数据盘 110G LVM xfs 挂 /data
- 宿主机：自编译 nginx 1.14.2（/application 前缀，链接 EL7 openssl 1.0.2/pcre），webtatic PHP 7.2 + swoole，postfix，ntpd，华为云 agent（uniagent / ICAgent / hostguard / CloudResetPwd*），categraf
- Docker 19.03 + docker-compose 1.29：xxl-job ×3（Java 8）、MySQL 5.7、ShardingSphere Proxy、Yearning 3.0.9、fail2ban、**NetBird VPN 路由容器**
- kubectl 1.21（rpm）+ helm 3.11，kubeconfig 指向托管 k8s 1.30
- **访问路径：操作端 → NetBird → 本机上的 NetBird 路由容器 → VPC**。即本机就是唯一入口
- 其它：自编译 openssh 9.8p1 rpm（SysV 脚本）、大量 pip 装进系统 site-packages 的 py2 包、sshd `ClientAliveCountMax 0`

## 2. 与业务方确认的决定
- 已做云服务器备份（CBR，系统盘+数据盘）；当场停机
- 中途确认：PHP 不再使用 → 删除；对应的 PHP 站点下线
- 追加需求：nginx 升到最新稳定版（1.30.x）、EL10 后全量更新软件

## 3. 时间线
| 阶段 | 结果 |
|---|---|
| 勘察 + 备份 + 基线 | 发现上述风险；两个反代站点升级前就是 502（后端未运行），记入基线 |
| EL7：yum 修源、update 到 7.9 | python-urllib3 因 pip 冲突安装失败 → 删 pip 版后补装 |
| 删 PHP、openssh 9.8 → 官方 7.4 | 用 systemd-run 脱离会话替换，新连接验证 OK |
| 7→8 预检 | 阻断：floppy/pata_acpi、多个 kernel-devel、pam_pkcs11 答案、mysql ld.so.conf；dnf 检查失败：docker nightly 源超时、EPEL metalink 极慢 |
| 7→8 升级重启 | **失联**（见 4.2）+ **initramfs 紧急模式**（见 4.1），经 VNC 救回 |
| EL8 收尾 | 旧 repo 指向 EPEL7 导致 distro-sync 冲突；nginx 静态重编（OpenSSL 1.1.1w + PCRE 8.45） |
| 8→9 | 阻断：VDO 检查答案；leapp 残留 exclude 挡住新 leapp 安装；Yearning 因 cgroup v2 崩溃 |
| 9→10 | 阻断：ifcfg 旧网络配置 ×5（nmcli migrate）；提示 libdb、nft_compat/ip_set |
| EL10 收尾 | nginx.org 1.30.6、docker-compose 包装、kubectl 1.30、helm 3.22、postfix lmdb、最终重启测试全绿 |

## 4. 遇到的问题

### 4.1 7→8 在 initramfs 中失败：pip 版 PyYAML 与 python2-pyyaml 冲突
- 现象：`upgrade.service failed`，`Error unpacking rpm package python2-pyyaml ... cpio: File from package already exists as a directory`，进入 emergency shell
- 原因：pip 装的 `yaml/`、`PyYAML-3.12-py2.7.egg-info` 占了 rpm 路径；只此一个包失败，但 leapp 后续阶段全部未执行（"半升级"）
- 处理：VNC 中只读挂载 /sysroot 确认 redhat-release 已是 8.10、Verifying 1500/1500、默认启动项为新内核 → 修复容器自启标记后重启 → 手工补做 leapp 收尾
- 预防：每跳前挪走所有不属于 rpm 的 site-packages 文件
- 状态：promoted → `pitfalls.md` §3 / `recovery.md` B、C；`survey.sh` BLOCKER 检测；`prep-el7.sh pipfix` / `hop.sh prep` 自动处理

### 4.2 重启前 `docker stop` 全部容器 → VPN 路由容器开机不自启 → 整个 VPC 失联
- 原因：NetBird 容器 `restart: unless-stopped`，被手动 stop 后 Docker 不会在开机时拉起
- 处理：VNC 中离线把 `config.v2.json` 的 `HasBeenManuallyStopped` 改为 false
- 预防：重启只停 `restart=always` 的有状态容器；VPN 容器永不手动停
- 状态：promoted → `pitfalls.md`、`hop.sh reboot`、`survey.sh`（VPN BLOCKER、unless-stopped HIGH）

### 4.3 远程操作自伤
- `pkill -f "<pattern>"` 匹配到自己的命令行，杀掉了自己的 SSH 会话（两次）
- OpenSSH 7.4 + `ClientAliveCountMax 0` 空闲 5 分钟踢会话
- Windows Git Bash 把 `/root/...` 参数改写为 `C:/Program Files/Git/root/...`
- 状态：promoted → `pitfalls.md` §1、`remote.py`（keepalive、MSYS 路径还原）、脚本统一 `systemd-run`

### 4.4 国内镜像
- 华为云镜像对该机返回 429；mirrorlist/metalink 极慢；leapp 厂商源 docker-ce 默认启用 nightly 段且超时 → 失败
- 状态：promoted → `hop.sh prep`（改阿里云镜像、关 test/nightly、探测可达）

### 4.5 cgroup v2：Yearning 3.0.9 FATAL `memory.limit_in_bytes: no such file`
- 处理：compose 挂只读 shim `./cgroupv1-shim:/sys/fs/cgroup:ro`
- 同时暴露：docker-compose 1.29 在 Docker 26 上 `KeyError: 'ContainerConfig'`，并已把旧容器改名为 `<id>_name`
- 状态：promoted → `app-compat.md`、`finalize.sh cgroupv1-shim / compose-wrapper`

### 4.6 其它
- `mysql-community-libs-compat` 直接删会连带删 postfix → `yum swap` 换回 mariadb-libs（promoted）
- 删 PHP 后某 PHP 站点 200→404：删除前应把"组件→站点"影响面告诉业务方（promoted：SKILL.md 阶段 0）
- 通配符证书 2.5 个月后到期：迁移 nginx 时顺带检查（promoted）

## 5. 结果对比（verify.sh）
| 检查项 | 升级前 | 升级后 |
|---|---|---|
| 8 个容器 | running | running（重启后自动拉起） |
| 静态 H5 站点 | 200 | 200 |
| 两个反代站点 | 502（后端未运行） | 502（同前，非本次引起） |
| 任务调度管理端 | 302 | 302 |
| SQL 审计 UI | 200 | 200 |
| PHP 站点 | 200 | 按决定下线 |
| kubectl get nodes | 2 Ready（client 1.21） | 2 Ready（client 1.30） |
| TLS | 1.0–1.2 | 1.2 / 1.3 |

## 6. 技能/脚本的不足
- 本报告时脚本尚未存在，均由本次手工命令提炼；首个使用脚本的 CentOS 7 实跑需要重点回归 `prep-el7.sh`、`swap-openssh.sh`、`hop.sh` 执行类子命令

## 7. 遗留事项
- CloudResetPwdAgent 升级前即失败，未处理
- cloud-init 已禁用（py2 egg 版本失效）
