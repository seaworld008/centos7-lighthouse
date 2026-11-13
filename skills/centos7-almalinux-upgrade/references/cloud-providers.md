# 云厂商差异：阿里云 / 华为云 / AWS

## 通用前置（每台都要）
1. 整机快照（系统盘 + 数据盘）——用户在控制台做，做完再开始。
2. 带外控制台**提前**确认能用（不是出事了才去试）。
3. 知道怎么连上这台机器：公网 IP + 安全组？VPN？跳板机？VPN 节点是否就是这台机器？

## 阿里云 ECS
- **快照**：ECS 控制台 → 实例 → 云盘 → 创建快照（或"快照一致性组"）。
- **带外**：远程连接 → VNC（首次需设置 VNC 密码）。另有**云助手**（Cloud Assistant / aliyun-service）可在控制台下发命令，SSH 不通时很好用；升级后确认 `aliyun-service`/`assist-daemon` 仍运行。
- **镜像源**：公网 `https://mirrors.aliyun.com`；ECS 内网 `http://mirrors.cloud.aliyuncs.com`（不耗公网流量，经典网络为 mirrors.aliyuncs.com）。路径统一：`/centos-vault/7.9.2009`、`/epel-archive/7`、`/almalinux`、`/epel`、`/docker-ce`、`/kubernetes-new`。
- **实测**（2026-11，CentOS 8 → AlmaLinux 10）：内网镜像 `mirrors.cloud.aliyuncs.com` 的 almalinux、epel、docker-ce、centos-vault 都可用，延迟约 66ms；服务器**访问不了 raw.githubusercontent.com**；aegis、云助手、云监控三跳之后都正常运行；镜像自带的 cloud-init 是源码安装的，EL9 上会失效（禁用即可）
- **agent**：云安全中心 aegis（/usr/local/aegis）、云监控 cloudmonitor/argusagent、云助手。升级后检查进程；aegis 可能对 leapp 的大量文件变更产生告警，提前告知安全负责人。
- 阿里云官方另有"操作系统迁移（CentOS → Alibaba Cloud Linux）"工具，若用户不坚持 AlmaLinux 可作为备选，但本技能统一目标为 AlmaLinux 10。

## 华为云 ECS
- **快照**：云备份 CBR → 云服务器备份（包含全部云硬盘）。
- **带外**：控制台 → 远程登录 → VNC（浏览器内）。Claude 可用浏览器工具操作：
  - 页面太矮看不到底部 → 点"全屏模式"再操作；看不到就滚动页面右侧
  - 长时间不动会 `Server disconnected (Client timeout)` → 重新打开 VNC 链接
  - 登录提示符需要输入密码时，请用户自己在 VNC 里登录（Claude 不代输密码）；initramfs 紧急 shell 无需密码
- **镜像源**：`https://repo.huaweicloud.com` 实测频繁 429 限流，优先用阿里云公网镜像。阿里云镜像偶尔也会对单机限速到几百 KB/s（多台并发时尤甚），换镜像前先测速。
- **agent**：uniagent/telescope（主机监控，systemd 原生 unit）、ICAgent（cron mstart.sh + SysV）、hostguard（HSS，SysV）、CloudResetPwdUpdateAgent / CloudResetPwdAgent（一键重置密码，SysV，自带 JRE）。AlmaLinux 10.2 下 SysV 仍可启动；坏了的按华为文档重装。
- 网卡：镜像常预置 ifcfg-eth0~eth4，9→10 时一起 `nmcli connection migrate`。
- sys_vendor：老规格显示 "OpenStack Foundation"；c9 等新规格显示 "Huawei Cloud"，CPU 型号被隐藏为 "General Purpose Processor"。规格名可从元数据取：`curl -s http://169.254.169.254/openstack/latest/meta_data.json` 的 `meta."metering.resourcespeccode"`（如 `c9.xlarge.2.linux`）。
- ★ **c9 规格只升到 AlmaLinux 9**：EL10 内核在升级 initramfs 早期加载驱动时挂死（见 pitfalls 9→10；与数据盘无关，黑名单 ata_piix 无效，均已用测试机验证）；s3、c3 实测正常。survey 会提示。验证某个规格能否上 10：按需开一台同规格 AlmaLinux 9.4 → `dnf upgrade` → hop.sh 9→10，设好定时删除。
- ★ **操作保护**：账号开了"敏感操作保护"时，强制关机/重启、删除云服务器等需要手机短信验证码，验证后约 15 分钟内同类操作免验证。提前告诉用户留在电脑前；Claude 不代输验证码。
- VNC：强制重启/开机后控制台要几秒才能重连，抢不到 GRUB 菜单；同一个 VNC 页面换 hash 地址重进（先进实例列表再进 VNC）才会重连。区域不在当前区域时，实例列表搜不到（如北京一 / 北京四）。
- 救援：同可用区内可以把系统盘卸下挂到别的机器上修改（recovery.md F）。

## AWS EC2
- **快照**：EBS Snapshot 或直接创建 AMI（推荐，含所有卷）。
- **带外**：EC2 Serial Console——需要账户级启用、Nitro 实例、且系统里有**可用密码的用户**（升级前创建/确认，并告诉用户由用户自己登录）。也可用 SSM Session Manager（amazon-ssm-agent 需运行、实例角色有权限）。
- **镜像源**：海外直接用上游（MIRROR=upstream）：vault.centos.org、archives.fedoraproject.org、repo.almalinux.org、download.docker.com、pkgs.k8s.io。
- **cloud-init**：AWS 上 cloud-init 负责 hostname、网络、SSH 公钥等，不要随手禁用。升级后安装新系统的 `cloud-init` 包，保留 `/var/lib/cloud`（instance-id 不变就不会重跑首启模块），检查 `cloud-init status`。
- 默认用户多为 `centos`（密钥登录，免密 sudo）；remote.py 用 `--user centos --key xxx.pem --sudo`（命令和上传都会以 root 执行）。
- 驱动：老机型（Xen，t2/m4）与 Nitro（ENA、NVMe）在 AlmaLinux 10 都支持；survey 关注 `lsmod` 中被移除的驱动。
- agent：amazon-ssm-agent、CloudWatch agent——升级后确认运行，必要时用官方 rpm 重装。

## 选择 MIRROR 速查
| 环境 | MIRROR |
|---|---|
| 阿里云 ECS（VPC） | `http://mirrors.cloud.aliyuncs.com`（不通则 `https://mirrors.aliyun.com`） |
| 华为云 / 其它国内 | `https://mirrors.aliyun.com` |
| AWS / 海外 | `upstream` |

先在目标机上 `curl -sI <MIRROR>/almalinux/10/BaseOS/x86_64/os/repodata/repomd.xml` 验证。
