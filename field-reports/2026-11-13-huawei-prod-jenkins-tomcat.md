---
date: 2026-11-13
cloud: huawei
profile: "生产 Jenkins 发布机：Tomcat 里的 Jenkins 2.275（JDK 8，手工启动，330 个任务）+ Nexus 容器 + PHP CLI 容器包装 + rsync 发布源 + JMeter 发布后验证"
source_version: CentOS 7.9
target_version: AlmaLinux 10.2
result: success
duration_hours: 2.6
skill_version: 0.6.2
operator: agent+human
---

# 华为云生产 Jenkins 发布机：CentOS 7.9 → AlmaLinux 10.2

单台生产 CI/发布机，所有业务的发布都经过它。用户要求：升级后 Jenkins 的发布流程和已有项目都要能正常发布。从 EL7 准备开始到最终重启测试约 2.6 小时（15:14 备份 → 17:19 最终重启），之后两次真实发布验证。

## 1. 机器画像（脱敏）
- 华为云 c3 规格（Xeon Gold 6151，x86-64-v3 支持，不是会在 EL10 升级 initramfs 卡死的 c9）；4 vCPU / 16G；系统盘 200G、数据盘 200G（LVM）。
- 业务：Tomcat 8 里跑 Jenkins 2.275（`/data/tomcat-8080`，自带 JDK 8u271，`JENKINS_HOME=/root/.jenkins`，330 个任务，workspace 54G）；Nexus 3 容器；php72-cli 容器 + `/usr/bin/php` 包装脚本（composer 构建用）；rsyncd（30 个模块，目标机从这里拉代码）；JMeter 5.6.2 + `python3.6`/pandas（发布后接口验证）；node 16、composer 在 /usr/local。
- 历史遗留：MariaDB 5.5（0 连接，6.9G 数据）、Grafana 6.4、Zabbix agent（rc.local 启动但没在跑）、httpd + gitweb（只有扫描器流量）。
- 访问路径：本机经 VPC 内另一台机器的 NetBird 路由访问，VPN 不在本机。
- survey 摘要：BLOCKER 2（110 个 pip 文件、宿主机 rpm MariaDB）；HIGH 6（手工启动的 java、5 个 kernel-devel、unless-stopped 容器、docker-compose v1、floppy/pata_acpi）；`/usr/bin/php` 被第三方 rpm 拥有且被替换过。

## 2. 与业务方确认的决定
- 快照：用户确认两块盘都已做快照/备份；窗口：当天下午，期间不发版。
- 删除：MariaDB 5.5、Grafana、Zabbix agent、httpd/gitweb（用户确认不用）。删除前冷备到数据盘（MariaDB 数据目录打包 2.6G），`yum remove` 先 `--assumeno` 演练确认只删目标包。
- JMeter 接口验证当前 18.75% 成功（测试用的 token 不对），用户说先放着；验收标准定为"升级前后同一个结果文件，报告输出一致"。

## 3. 时间线
| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|
| 15:01 | 清理 MariaDB/Grafana/Zabbix/httpd | 冷备后卸载；期间触发了数据盘 I/O >90% 告警（打包 6.9G）|
| 15:14 | backup.sh | 基线、手工进程环境（manual-procs）|
| 15:18 | 镜像测速 | 华为云 20MB/s，阿里云 157KB/s → 选华为云 |
| 15:20 | prep-el7 repos/update/pipfix/inhibitors | remi 源 404 自动禁用；remi PHP 卸载，`/usr/bin/php` 包装放回（不再属于任何 rpm）|
| 15:33 | 7→8 pre | leapp 起不来：`No module named urllib3.exceptions`（4.1）|
| 15:44 | Jenkins 改 systemd | 手工进程 → `jenkins-tomcat.service`，环境与原进程一致 |
| 15:45-16:07 | 7→8 up / reboot | 2397 个包；16:07 到 8.10 |
| 16:08 | Jenkins `/` 404 | 同一个 war 部署两次（4.2），关自动部署后恢复 |
| 16:15-16:44 | 8→9 | VDO/firewalld 自动回答；16:44 到 9.8；compose v2 包装 |
| 16:47-17:12 | 9→10 | ifcfg→keyfile；17:12 到 10.2 |
| 17:15 | 收尾 | EPEL python3-pandas + python3.6 转发，JMeter 报告输出与升级前一致 |
| 17:19 | 最终重启测试 | 66 秒回来，全部服务自启 |
| 17:22 | 真实发布 #499 | 失败：`Host key verification failed`（4.3）|
| 17:40 | 补齐 known_hosts 后 #500 | 成功；用户随后又发布了几个项目，正常 |

## 4. 遇到的问题

### 4.1 pipfix 之后 leapp 起不来
- 阶段：7→8 pre
- 现象：preupgrade "无报告"，日志：`ImportError: No module named urllib3.exceptions`（leapp → requests → urllib3）。
- 原因：`python-urllib3` rpm 当年被 `--nodeps` 删掉、换成 pip 版；pipfix 挪走 pip 文件后 `python-requests` rpm 的依赖露出来。
- 处理：`yum install python-urllib3 && yum reinstall python-requests`，重跑 pre 通过。
- 预防：`prep-el7.sh pipfix` 现在跑 `yum check dependencies` 补装缺失依赖并验证 `import requests`；冒烟测试复现了这个场景。
- 状态：promoted → `pitfalls.md` EL7 准备、`prep-el7.sh`、`tests/container-smoke.sh`

### 4.2 Tomcat 把同一个 war 部署两次，重启后 `/` 404
- 阶段：7→8 重启后
- 现象：`/login` 404、`/jenkins/login` 200；`authentication-filter` 启动失败 `key cannot be empty or null`，`Context [] startup failed`。
- 原因：`<Context path="" docBase="jenkins.war">` + Host `autoDeploy="true"`，同一个 war 以 `/` 和 `/jenkins` 起两个 Jenkins，共用 JENKINS_HOME 抢启动。升级前一次切换 systemd 时两个都起来了（之前能用是运气）。
- 处理：第一次误判成"多余的副本"把 `jenkins.war` 挪走，Tomcat 整个起不来（它就是 ROOT 的 docBase）→ 立刻放回；最终在 Host 上加 `autoDeploy="false" deployOnStartup="false"`，只剩一个实例，之后每次重启都正常。
- 预防：survey 报这种 server.xml（MEDIUM）；pitfalls 写明"不要挪 war"。
- 状态：promoted → `pitfalls.md` 应用层、`survey.sh`、冒烟测试

### 4.3 EL10 上发布任务 `Host key verification failed`
- 阶段：升级完成后第一次真实发布
- 现象：任务里 `ssh -p 10015 目标机 'docker pull ...'` 失败；同一个任务里前面对另外两台的 ssh/rsync 成功。免密本身正常（用户以为要重新做免密，其实不用）。
- 原因：EL10 crypto-policies 显式设置 `HostKeyAlgorithms`，OpenSSH 不再优先协商 known_hosts 里已有的类型，直接用 ed25519；known_hosts 64 条里 62 条只有 ECDSA。
- 处理：用已信任的 ECDSA 连上去读取对方主机公钥补齐（新增 `known-hosts-fill.sh`）；记录为 22 端口、实际 10015 的条目再试一次。`UpdateHostKeys=yes` 试过不行（固定 HostKeyAlgorithms 后只接收同类型）。排查时还踩到 ControlMaster 复用：一度"修好了"其实是复用了旧连接，加 `-o ControlPath=none` 才看到真相。
- 全量核对：从全部 330 个任务配置里提取 80 个地址逐个按发布方式测试——原来有记录的 ssh 目标全部通过；9 个失败的地址从来不在 known_hosts 里（多为镜像仓库/HTTP 地址），与升级无关。
- 状态：promoted → `pitfalls.md` 应用层、`known-hosts-fill.sh`、`survey.sh`（EL7-9 提示）、`hop.sh post`（到 10 后提醒）

### 4.4 其它（只留在报告里）
- 镜像测速和上一台华为云主机的结论相反（这次华为云快、阿里云慢）→ pitfalls 里改成"每次都测"。
- 用户准备好的 mihomo 代理这次没用上；代理部署在另一台机器上，按需启动。
- 华为云"一键重置密码"插件 `cloudResetPwdAgent` 升级前后都是 failed，不是本次引入。
- JMeter 用例 18.75% 是测试 token 问题，用户另行处理。

## 5. 结果对比（verify.sh）
| 检查项 | 升级前 | 升级后 | 备注 |
|---|---|---|---|
| OS | CentOS 7.9 | AlmaLinux 10.2 | kernel 6.12 |
| Jenkins | 手工 startup.sh，2 个实例 | systemd 自启，1 个实例 | `/login` 200 |
| Docker / compose | 26.1.4 / v1 1.23.2 | 29.4.1 / v2 包装 | 容器 project 名一致，没有重建 |
| git / rsync | 1.8.3 / 3.1 | 2.52 / 3.5 | |
| php（容器包装）/ composer | 可用 | 可用 | `/usr/bin/php` 不再属于 rpm |
| JMeter 报告 | 18.75% | 18.75% | 同一结果文件，输出完全一致 |
| 端口 | tcp/45882 | 无 | 华为云插件的随机端口，非业务 |
| 真实发布 | — | #500 成功 + 用户多次发布 | |

## 6. 技能/脚本的不足
- pipfix 没检查 rpm 依赖完整性（已修）。
- 没有针对"CI 发布机的 ssh 目标"的检查（已加 survey 提示、hop post 提醒、补齐脚本）；这类问题只有真实发布才暴露，验收必须包含一次真实发布。
- Tomcat 部署结构没有检查（已加）。

## 7. 遗留事项
- 数据盘上 23G 旧备份（多年来备份的一直是一份过期副本）待用户确认后删除。
- Jenkins 2.275 / JDK 8 很老，另起变更升级。
- JMeter 测试 token 由用户修正。
