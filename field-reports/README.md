# Field Reports（实战报告）

每一次真实的升级都在这里留下一份**脱敏**报告。这是本仓库的经验来源：

```
真实执行 → field-reports/ 记录 → 反复出现/影响大的问题 → 提炼进 skills/.../references/pitfalls.md
                                                          → 能自动检测的加进 survey.sh
                                                          → 能自动修复的改进 hop.sh / prep-el7.sh / finalize.sh
```

## 规则
- 文件名：`YYYY-MM-DD-<cloud>-<profile>.md`，例如 `2026-11-05-huawei-jumphost-docker-vpn.md`
- 从 [TEMPLATE.md](TEMPLATE.md) 复制，**所有字段都要填**（不知道写 `unknown`）
- **必须脱敏**：不写真实 IP、域名、主机名、账号、密码、公司/客户名、镜像仓库地址。IP 用 `10.0.0.x`，域名用 `example.com`。提交前跑 `python tools/check_repo.py`
- 失败、回滚、做到一半的也要写，失败的经验比成功的更值钱
- 报告里每个新问题标明是否已经**提炼**（`promoted: pitfalls.md#xxx` / `not yet`）

## 索引
| 日期 | 云 | 画像 | 路径 | 结果 | 报告 |
|---|---|---|---|---|---|
| 2026-11-06 | 阿里云 | 测试应用机：PHP 应用容器 ×4 + MySQL8/Redis 容器 + 宿主机 tarball MySQL 5.7 + cron docker exec | CentOS 7.9 → Alma 8.10 → 9.8 → 10.2 | ✅ 成功（全程脚本，约 1.9 小时；修复 4 处） | [link](2026-11-06-aliyun-test-apps-hostmysql-centos7.md) |
| 2026-11-06 | 阿里云 | 镜像仓库 Harbor + YApi + MySQL 容器 + 雷池 WAF + 自编译 LNMP | CentOS 7.6 → 7.9 → Alma 8.10 → 9.8 → 10.2 | ✅ 成功（首台全程用脚本完成的 CentOS 7；执行中修复 12 处脚本问题） | [link](2026-11-06-aliyun-registry-waf-lnmp-centos7.md) |
| 2026-11-06 | 阿里云 | 堡垒机（JumpServer 11 个容器）+ openresty 容器 + firewalld | CentOS 8.3 → Alma 8.10 → 9.8 → 10.2 | ✅ 成功（首次全程使用脚本；执行中修复 9 处脚本问题） | [link](2026-11-06-aliyun-bastion-docker-centos8.md) |
| 2026-11-05 | 华为云 | 跳板机 + Docker 业务 + VPN 路由 + 自编译 nginx | 7.7 → 8.10 → 9.8 → 10.2 | ✅ 成功（7→8 一次 initramfs 失败后救回） | [link](2026-11-05-huawei-jumphost-docker-vpn.md) |
