---
date: YYYY-MM-DD
cloud: aliyun | huawei | aws | other
profile: <一句话画像，如 "web + docker + mysql in container">
source_version: CentOS 7.x
target_version: AlmaLinux 10.x
result: success | partial | rolled-back | aborted
duration_hours: <总时长>
skill_version: <plugin.json 的 version>
operator: human | agent | agent+human
---

# <标题>

## 1. 机器画像（脱敏）
- 硬件 / 虚拟化 / 启动方式 / CPU x86-64-v3：
- 磁盘布局（系统盘大小与剩余、数据盘）：
- 业务组件（宿主机进程 / 容器 / 定时任务）：
- 访问路径（公网 / VPN / 跳板；VPN 是否运行在本机）：
- survey.sh 的 BLOCKER / HIGH 摘要：

## 2. 与业务方确认的决定
- 快照：是/否；停机窗口：
- 下线 / 删除的组件：
- 其它：

## 3. 时间线
| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|

## 4. 遇到的问题
每个问题一节：

### 4.x <问题标题>
- 阶段：EL7 准备 / 7→8 / 8→9 / 9→10 / 收尾
- 现象（原始报错，脱敏）：
- 原因：
- 处理：
- 预防（脚本/检查项改进建议）：
- 状态：promoted → `references/pitfalls.md` 的哪一节 / not yet

## 5. 结果对比（verify.sh）
| 检查项 | 升级前 | 升级后 | 备注 |
|---|---|---|---|

## 6. 技能/脚本的不足
- 哪一步脚本没覆盖、需要手工处理：
- 文档哪里不清楚：

## 7. 遗留事项
-
