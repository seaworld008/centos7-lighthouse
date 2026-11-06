# 批量推进（几十到上百台）

## 1. 资产表
一个 xlsx/csv 管所有机器（remote.py 直接读）：`name, host, port, username, password, cloud, region, owner, business, notes`。
另用 `assets/fleet-tracker.csv` 跟踪进度（每台一行：阶段、分类、阻断项、负责人确认、快照时间、各跳完成时间、结果）。

## 2. 并行勘察（只读，可以全部同时跑）
```bash
for h in $(python remote.py --list | cut -f2); do
  ( python remote.py $h put $S /root/os-upgrade-kit >/dev/null &&
    python remote.py $h run "bash /root/os-upgrade-kit/survey.sh" --timeout 600 > fleet/$h/survey.txt 2>&1 ) &
done; wait
grep -H "^\[BLOCKER\]\|^\[HIGH\]" fleet/*/survey.txt
```
每台建目录 `fleet/<host>/`：survey.txt、decisions.md（用户确认的去留决定）、log.md（每步做了什么）、report.md。

## 3. 分类
| 类 | 特征 | 策略 |
|---|---|---|
| A 简单 | 无 BLOCKER，只有系统服务/少量容器 | 批量升级，脚本流程基本不用改 |
| B 容器型 | Docker 容器为主 | 注意 restart 策略、compose v1、cgroup v1 镜像；或直接新建机器重部署 |
| C 定制型 | 自编译程序、宿主机数据库、PHP/Java 直接跑 | 逐台处理，先定每个组件方案 |
| D 不原地 | k8s 节点、关键大库、btrfs、CPU 不支持 v3 | 新建 AlmaLinux 10 机器迁移业务 |
| ⚠ 访问路径 | 本机运行 VPN/隧道/跳板 | 单独排期，最后做；控制台随时待命 |

## 4. 金丝雀 → 分批
1. 每类先挑 1 台非关键机器完整走一遍（含最终重启测试），把新遇到的坑补进 pitfalls.md。
2. 之后按业务分批：同一业务的主备/集群节点**不要同一批**；一批内同时重启的数量控制在能盯得过来的范围（控制台窗口数）。
3. 下载阶段（hop.sh prep/pre/up）可多台并行；重启阶段逐台或小批量进行。
4. 每台完成后 verify.sh 全绿 + 最终重启测试通过才标记完成。

## 5. 每台的固定节奏（可直接照做）
勘察 → 用户确认（快照/窗口/控制台/去留决定） → backup.sh → prep-el7.sh → [hop.sh prep/pre/answer/up/reboot/post + verify] ×3 → finalize → 最终重启 + verify → 报告。

## 6. 记录
- 新坑：现象 / 原因 / 处理写回 `references/pitfalls.md`，让下一台受益。
- 每台报告按 `assets/report-template.md`。
