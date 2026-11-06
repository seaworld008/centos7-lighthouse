<div align="center">

<img src=".claude-plugin/icon.png" width="128" alt="CentOS 7 Lighthouse">

# CentOS 7 Lighthouse 🗼

**A lighthouse for everyone still running CentOS 7 in the AI era.**
Upgrade CentOS 7 servers **in place to AlmaLinux 10**: workloads keep running, you don't lose access, and every step can be rolled back and verified.

[![CI](https://github.com/seaworld008/centos7-lighthouse/actions/workflows/ci.yml/badge.svg)](https://github.com/seaworld008/centos7-lighthouse/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/seaworld008/centos7-lighthouse?color=0F4266)](https://github.com/seaworld008/centos7-lighthouse/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CentOS 7 → AlmaLinux 10](https://img.shields.io/badge/CentOS%207-%E2%86%92%20AlmaLinux%2010-0F4266?logo=almalinux&logoColor=white)](https://almalinux.org/)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-skill%20%2B%20plugin-D97757?logo=anthropic&logoColor=white)](https://docs.claude.com/en/docs/claude-code)
[![Agent-first](https://img.shields.io/badge/maintained%20by-AI%20agents%20%2B%20humans-7B61FF)](AGENTS.md)

[中文](README.md) · [Pitfalls](skills/centos7-almalinux-upgrade/references/pitfalls.md) · [Field reports](field-reports/) · [For AI agents](AGENTS.md)

</div>

> The detailed docs (SKILL.md, references) are currently in Chinese. AI agents read them fine; English translations are on the [roadmap](ROADMAP.md) and PRs are welcome.

## Why

CentOS 7 reached end of life in June 2024. Many fleets still run it, each server with its own mix of workloads: self-built nginx, Docker containers, Java jobs, databases, VPNs. In practice, in-place upgrades rarely fail because of Leapp itself. They fail because of the **unofficial stuff** on the box. This project turns every pitfall from a real production migration into automated detection, automated handling, and recovery runbooks:

- pip packages in system site-packages abort the upgrade halfway through the initramfs → flagged as BLOCKER and moved aside before every hop
- `docker stop`-ing all containers before a reboot kept the on-host VPN container from restarting, cutting off the whole VPC → `hop.sh reboot` stops only stateful `restart=always` containers and never touches VPN containers
- self-built openssh/nginx linked against EL7 libraries won't start after the upgrade → openssh is swapped back to the distro package (with automatic fallback); nginx is rebuilt statically, then replaced by the nginx.org package
- mirrors throttled (HTTP 429) and docker nightly repos timing out → mirrors are rewritten and probed; test/nightly repo sections are disabled
- cgroup v2 crashes old apps, and docker-compose v1 breaks on Docker ≥25 → cgroup v1 shim and a compose v2 wrapper

## What you get

- **`survey.sh`**: read-only risk report, graded BLOCKER / HIGH / MEDIUM / INFO
- **`backup.sh` / `verify.sh`**: business baseline (services, ports, containers, per-vhost HTTP codes, kubectl), compared after every hop
- **`hop.sh`**: one ELevate hop at a time: prep → preupgrade → report/answer → upgrade → safe reboot → post-cleanup. Long tasks run under `systemd-run`, so a dropped SSH session doesn't interrupt them
- **`prep-el7.sh`, `swap-openssh.sh`, `nginx-static-build.sh`, `finalize.sh`**: EL7 preparation and EL10 modernization (nginx.org stable, kubectl matched to your cluster, helm, postfix lmdb)
- **`fleet_summary.py`**: aggregates many `survey.txt` files, classifies each host (A/B/C/D, VPN, CentOS 8), and proposes a canary plus batches (HA pairs are kept in different batches)
- **Runbooks**: pitfalls, app compatibility, Alibaba Cloud / Huawei Cloud / AWS specifics, initramfs emergency-shell recovery, fleet rollout

## Quick start

```
/plugin install centos7-almalinux-upgrade --marketplace seaworld008/centos7-lighthouse
```
Then just ask Claude Code: *"Upgrade the CentOS 7 server 10.0.0.11 to the latest AlmaLinux without breaking its services."*

You can also copy `skills/centos7-almalinux-upgrade` into `~/.claude/skills/`, or use the scripts directly without AI (see [README.md](README.md#方式三不用-ai直接用脚本)).

## Verification status

- The full procedure (as manual commands) worked on a production Huawei Cloud server, CentOS 7.7 → AlmaLinux 10.2, with all services restored ([field report](field-reports/2026-11-05-huawei-jumphost-docker-vpn.md)).
- Fully scripted run: an Alibaba Cloud bastion host went CentOS 8.3 → AlmaLinux 10.2 using `convert-el8.sh` + `hop.sh` (8→9→10) + `verify.sh`. All 12 containers and 11 vhosts matched the baseline, and the final reboot test passed ([field report](field-reports/2026-11-06-aliyun-bastion-docker-centos8.md)).
- CI runs smoke tests in CentOS 7 / AlmaLinux 8/9/10 containers.
- Not yet regression-tested as scripts: `prep-el7.sh`, `swap-openssh.sh`, the 7→8 hop, and `finalize.sh` (tracked in issue #5). **Try a non-critical server first, and take a full snapshot.**

## Agent-first

AI agents do most of the reading, running, improving and documenting in this repo; humans review and make the decisions. Every real run produces a sanitized [field report](field-reports/), and what it teaches gets distilled into the pitfalls, `survey.sh` detections, and the scripts. Agents: start with [AGENTS.md](AGENTS.md). Humans: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Built on AlmaLinux [ELevate](https://wiki.almalinux.org/elevate/) and [Leapp](https://github.com/oamg/leapp).
