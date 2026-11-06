# 贡献指南 / Contributing

感谢你帮忙让更多 CentOS 7 平稳上岸！人类和 AI agent 都欢迎贡献。**Agent 请先读 [AGENTS.md](AGENTS.md)**，那里是完整的规则。

## 最有价值的贡献（按优先级）
1. **实战报告**：真实升级一台机器后，按 [field-reports/TEMPLATE.md](field-reports/TEMPLATE.md) 写一份脱敏报告（失败的也要）。
2. **新坑**：写进 `skills/centos7-almalinux-upgrade/references/pitfalls.md`，格式为"现象 → 原因 → 处理"，放到对应的跳或阶段。
3. **自动检测**：能提前发现的问题，在 `survey.sh` 加一个分级 `flag`。
4. **自动修复**：改进 `prep-el7.sh` / `hop.sh` / `finalize.sh`，并给 `tests/container-smoke.sh` 加覆盖。
5. 新的云厂商、新的应用兼容方案、文档改进、英文翻译。

## 流程
1. Fork / 新建分支，例如 `pitfall/el9-xxx`、`report/2026-12-01-aws-web`
2. 修改后本地自检：
   ```bash
   python tools/check_repo.py
   shellcheck -S warning -e SC2010 -s bash skills/*/scripts/*.sh tests/*.sh
   bash tests/container-smoke.sh        # 需要 docker
   ```
3. 提交信息遵循 Conventional Commits：`feat:` `fix:` `docs:` `pitfall:` `report:` `ci:`
4. 提 PR，按模板写清"验证状态"（真实机器 / 容器冒烟 / 未测）
5. 更新 `CHANGELOG.md` 的 `[Unreleased]`

## 脱敏规则（硬性）
- 不得出现真实 IP、域名、主机名、账号、密码、密钥、公司或客户名、私有镜像仓库地址
- 示例统一用 `10.0.0.x`、`example.com`、`web-01`
- `tools/check_repo.py` 和 CI 的 gitleaks 会拦截常见模式，但它们不能代替你自己检查

## 脚本兼容性要求
`scripts/*.sh` 在目标机上运行，必须兼容 CentOS 7（bash 4.2、无 python3、老版本 coreutils/iproute）一直到 AlmaLinux 10。具体规则见 AGENTS.md「铁律 3」。

---

**English summary**: The most valuable contributions are sanitized field reports from real runs, new pitfalls (symptom → cause → fix), detections in `survey.sh`, and automation in the hop scripts. Run `python tools/check_repo.py` and shellcheck before opening a PR, state the verification level honestly, and never include real IPs, domains, hostnames or credentials. AI agents: read [AGENTS.md](AGENTS.md) first.
