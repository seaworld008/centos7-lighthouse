---
date: 2026-11-19
cloud: aliyun+huawei
profile: "升级后集中体检：约 38 台（其中 17 台由本技能 leapp 升级到 AlmaLinux 9.8/10.2，其余是没有跨大版本升级的机器：全新安装的 AlmaLinux、仍是 CentOS 7 的机器），找出 verify.sh 发现不了的慢性问题"
source_version: CentOS 7.x / CentOS 8.x（升级前）
target_version: AlmaLinux 9.8 / 10.2
result: success
duration_hours: unknown
skill_version: 0.6.3
operator: agent+human
---

# 升级后集中体检：阿里云 + 华为云约 38 台

不是一次升级，而是对整个机群做的一次"升级后体检"。起因：升级当天 `verify.sh` 全绿，但几天后用户发现 `vi` 每次启动都报错、有的日志没轮转。用户要求把所有机器都查一遍，问题都修掉，并把检查固化成脚本。

## 1. 机器画像（脱敏）
- 两个云：阿里云约 15 台、华为云约 25 台（含 2 台因 c9 规格退回 AlmaLinux 9.8 的机器）。
- 17 台由本技能从 CentOS 7/8 经 leapp 升级而来（7→8→9→10，或停在 9.8）；其余是全新安装的 AlmaLinux 或仍是 CentOS 7 的机器，作为对照组。
- 业务：Docker/Compose、K8s 节点、宿主机 MySQL、Jenkins、nginx、各种云厂商 agent。
- 访问路径：经 VPN 路由，按机器批量执行只读脚本，结果回传到本机汇总。
- 方式：先写一个只读检查脚本（后来成为 `post-audit.sh`），在全部机器上跑，按级别汇总；逐项定原因，确认后修复，修复后再跑一次。

## 2. 与业务方确认的决定
- 快照：只改配置文件（每台改动前备份到 `/root/post-upgrade-fix-<日期>/`），不重启、不动业务进程，未单独做快照。
- 不自动处理：limits 写错的行（改正后限制才第一次真正生效）、非标准名字的失效链接、云厂商插件。
- 生产 Jenkins 的 `/manage` 告警顺带处理（与升级无关，只留在本报告）。

## 3. 时间线
| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|
| 1 | 发现 `vi` E319；全机群排查 virc | 全部 leapp 升级到 9+ 的机器都有，全新安装的没有 |
| 2 | 写只读检查脚本，全机群跑 | 汇总出约 12 类问题 |
| 3 | 逐类定原因、修复、复验 | 见第 4 节 |
| 4 | 固化：`post-audit.sh`、`hop.sh tidy`、冒烟测试；在 11 台真实机器上复跑 | 输出与人工结论一致；tidy 在已修好的机器上是 no-op |

## 4. 遇到的问题

### 4.1 logrotate 没有被调度，日志从升级那天起不再轮转
- 阶段：收尾（升级完成后）
- 现象：`systemctl list-timers` 没有 logrotate，`/etc/cron.daily/logrotate` 也不存在；17 台升级机全部如此，全新安装的机器 `logrotate.timer` 是 enabled。
- 原因：EL9 起由 `logrotate.timer` 调度，只有全新安装时按 preset 启用；leapp 升级不对新增 unit 执行 preset（上游 RHEL-17361）。
- 处理：`systemctl enable --now logrotate.timer`；再 `logrotate -d` 检查配置，修掉 `logrotate.d` 里的 `.bak` 副本（重复定义，`duplicate log entry`）和需要 `su` 的日志目录。
- 预防：`hop.sh tidy`（post 末尾自动执行）；`post-audit.sh` 报 HIGH / MEDIUM。
- 状态：promoted → `pitfalls.md` 第 6 节、`hop.sh tidy`、`post-audit.sh`

### 4.2 `vi` 启动报 E319
- 阶段：8→9 后一直存在
- 现象：`E319: Sorry, the command is not available in this version`，`crontab -e`、`visudo` 都会弹。
- 原因：leapp 往 `/etc/virc` 追加了只有完整 vim 才认识的 `let`/`filetype` 行；vi 是 vim-minimal。
- 处理：virc 没有其它自定义内容时用 `virc.rpmnew` 替换（先备份）。约 38 台里所有 leapp 升级到 9+ 的机器都修了。
- 状态：promoted → `pitfalls.md` 第 6 节、`hop.sh tidy`、`post-audit.sh`

### 4.3 EL7 专用 sysctl `fs.may_detach_mounts`
- 现象：开机 `systemd-sysctl` 报 `Couldn't write`。
- 处理：注释掉；跳过 `99-sysctl.conf` 这种链接，只改真实文件。
- 状态：promoted → `pitfalls.md` 第 6 节、`hop.sh tidy`

### 4.4 limits.conf 写错的行
- 现象：两台仍是 CentOS 7 的机器上 limits 有写错的行，从来没生效过；每次登录、每个 cron 任务都在 secure 日志里记 `pam_limits` 错误，多年没人看。
- 处理：与用户确认后注释（不改成"本意"的值，避免限制突然生效）；之后不再出现新的 pam_limits 错误。
- 状态：promoted → `pitfalls.md` 第 6 节、`post-audit.sh`（只报不改）

### 4.5 已删除旧服务的失效启用链接
- 现象：`vdo.service`、`rhel-*.service`、`lvm2-lvmetad` 等指向不存在文件的链接。
- 处理：已知名字的删除（留清单）；3 台阿里云机器上非标准名字的失效链接只报告，交给用户确认。
- 状态：promoted → `hop.sh tidy`、`post-audit.sh`

### 4.6 `docker-ce.repo` 写死 `centos/7`
- 现象：升级到 10 后 docker-ce/containerd 仍是 el7 的包，没有任何报错。
- 原因：同一文件的其它段用了 `$releasever`，`hop.sh post` 的"写死旧版本"规则因此跳过。另一台机器上一个 EL7 时代的源在 7→8 时漏掉，之后每跳只按"上一跳版本号"匹配，一直没被挪走。
- 处理：写死的版本号改回 `$releasever`；post 的匹配改为 7…上一跳的所有版本号。
- 状态：promoted → `hop.sh tidy`、`hop.sh post`

### 4.7 云厂商数据库审计 agent 缺 `libldap-2.4.so.2`
- 现象：agent 的 unit failed，`ldd` 显示 libldap/liblber-2.4 not found。
- 处理：`dnf install openldap-compat`，重启 agent 后正常。
- 预防：`hop.sh prep`（目标 ≥9）发现运行中的非 rpm 程序依赖这两个库时写进 leapp `to_install`（未在真实升级中验证）。
- 状态：promoted → `pitfalls.md` 第 6 节、`hop.sh prep`、`post-audit.sh`

### 4.8 unit 的键写在 `[Install]` 段
- 现象：`Unknown key name ... in section 'Install', ignoring`，这些键从来没生效。
- 处理：挪到 `[Service]` 段，`daemon-reload`。
- 状态：promoted → `pitfalls.md` 第 6 节、`post-audit.sh`

### 4.9 退回 9.8 的 c9 机器带着 leapp 残留
- 现象：ELevate 源、leapp 包、`/var/lib/leapp` 升级用户空间、`/boot` 下的升级内核文件都还在。
- 处理：确认没有升级启动项后清理。
- 状态：promoted → `recovery.md` F 第 7 步、`post-audit.sh`

### 4.10 其它（只留在报告里）
- 华为云 `cloudResetPwdAgent` 在所有机器上升级前后都是 failed，非本次引起。
- 一台华为云机器的 `cloudResetPwdUpdateAgent` restart 后不写 pid 文件、一直 failed（同版本其它机器正常），交给云厂商（已写进 pitfalls 的云插件条目）。
- 生产 Jenkins（容器）的 `/manage` 告警：卸载 3 个已弃用插件、完成 built-in 节点改名迁移、启用 CSP；与 OS 升级无关。

## 5. 结果对比
| 检查项 | 修复前 | 修复后 | 备注 |
|---|---|---|---|
| logrotate 调度（17 台升级机） | 0/17 | 17/17 | 全新安装的机器本来就正常 |
| `vi` 启动报错 | 所有 leapp 升级到 9+ 的机器 | 0 | |
| `post-audit.sh` 复跑（11 台） | — | HIGH 只剩升级前就有的云厂商插件 | |
| `hop.sh tidy` 在已修好的机器上 | — | no-op | 4 台实测 |

## 6. 技能/脚本的不足
- `verify.sh` 只对比业务基线，像"日志不轮转""每次登录记错误"这类过几天才出问题的项完全看不见 → 新增 `post-audit.sh`，SKILL 阶段 4 加一步。
- `hop.sh post` 的旧源匹配只看上一跳版本号，前面漏掉的源会一直留着（已修）。
- leapp 不对新增 unit 执行 preset 是普遍问题，logrotate 之外可能还有别的 timer；`post-audit.sh` 只查了已知的这一个。

## 7. 遗留事项
- 3 台阿里云机器上非标准名字的失效链接待用户确认。
- 华为云 `cloudResetPwdAgent` / 个别 `cloudResetPwdUpdateAgent` 交给云厂商。
