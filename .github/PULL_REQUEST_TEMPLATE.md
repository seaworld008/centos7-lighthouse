## 改了什么 / What

## 为什么 / Why
<!-- 关联的 issue / field report / pitfall -->

## 验证状态 / Verification
- [ ] verified-on-real-run：在真实服务器上跑过（写明系统版本、云）
- [ ] 容器冒烟测试通过（`bash tests/container-smoke.sh` 或 CI smoke）
- [ ] untested：只改了文档 / 尚未实测（请说明原因）

## 检查清单 / Checklist
- [ ] `python tools/check_repo.py` 通过（无敏感信息、版本一致）
- [ ] shellcheck / `bash -n` 通过；脚本兼容 EL7（bash 4.2、无 python3）到 EL10
- [ ] 新坑已写进 `references/pitfalls.md`；能检测的已加进 `survey.sh`
- [ ] 真实执行已写 `field-reports/` 并更新索引
- [ ] `CHANGELOG.md` 的 `[Unreleased]` 已更新
- [ ] 会改变业务行为的操作写成"向用户确认"，没有写成自动执行
- [ ] 作者：人 / AI agent（agent 提交请加 `agent-authored` 标签）
