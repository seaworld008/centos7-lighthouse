#!/usr/bin/env python3
"""fleet_summary.py - 汇总多台服务器的 survey.sh 结果，按 references/fleet.md 的规则分类，并给出金丝雀与升级批次建议。

用法：
  python fleet_summary.py fleet/                      # 读取 fleet/<host>/survey.txt（或 fleet/*.txt）
  python fleet_summary.py fleet/ --groups groups.csv  # CSV 列: host,group —— 同一 group（同业务主备/集群）不放同一批
  python fleet_summary.py fleet/ --batch 5 --json     # 每批最多 5 台；--json 输出机器可读结果

输出 Markdown：分类统计 → 每台机器一行 → 建议批次。只依赖 Python 3 标准库（本机运行，不在目标机上运行）。

分类（与 references/fleet.md 一致）：
  D  不原地：k8s 节点、宿主机 rpm 数据库、CPU 不支持 x86-64-v3、btrfs、非 x86_64 → 新建机器迁移
  C  定制型：自编译程序依赖 EL7 库、非官方 openssh、webtatic PHP、宿主机 Java 8/11/17 → 逐台定方案
  B  容器型：有 Docker 容器 → 注意 restart 策略 / compose v1 / cgroup v1
  A  简单：以上都没有
  另外标记 VPN（本机运行 VPN/隧道，单独排期、最后做）和 EL8（CentOS 8 源，先 convert-el8.sh）
"""
import argparse
import csv
import glob
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:  # pragma: no cover
    pass

RULES_D = ("Kubernetes 节点", "rpm 版数据库服务", "x86-64-v3", "btrfs", "架构 ")
RULES_C = ("自编译程序", "openssh-server 不是发行版官方包", "PHP 来自 webtatic", "宿主机 Java")
RULE_VPN = "VPN/隧道"
CLASS_ORDER = {"A": 0, "B": 1, "C": 2, "D": 3}


def parse_survey(text):
    info = {"source": "unknown", "el": None, "cloud": "unknown", "v3": None, "containers": 0, "flags": []}
    m = re.search(r"===== OS =====\n(.+)", text)
    if m:
        info["source"] = m.group(1).strip()
    m = re.search(r"\bel=(\d+)", text)
    if m:
        info["el"] = int(m.group(1))
    m = re.search(r"\bcloud=(\w+)", text)
    if m:
        info["cloud"] = m.group(1)
    m = re.search(r"x86-64-v3: (YES|NO)", text)
    if m:
        info["v3"] = m.group(1) == "YES"
    dsec = re.search(r"===== DOCKER/CONTAINERS =====\n(.*?)\n===== ", text, re.S)
    if dsec:
        info["containers"] = len(re.findall(r"^/[\w.\-]+ \| ", dsec.group(1), re.M))
    fsec = re.search(r"#+ RISK FLAGS #+\n(.*?)\n#+", text, re.S)
    if fsec:
        for line in fsec.group(1).splitlines():
            m = re.match(r"\[(BLOCKER|HIGH|MEDIUM|INFO)\] (.*)", line.strip())
            if m:
                info["flags"].append((m.group(1), m.group(2)))
    return info


def classify(info):
    msgs = [m for _, m in info["flags"]]
    reasons = []
    cls = "A"
    for key in RULES_D:
        hit = [m for m in msgs if key in m]
        if hit:
            cls = "D"
            reasons.append(hit[0][:60])
    if cls != "D":
        for key in RULES_C:
            hit = [m for m in msgs if key in m]
            if hit:
                cls = "C"
                reasons.append(hit[0][:60])
    if cls == "A" and info["containers"] > 0:
        cls = "B"
        reasons.append("%d 个容器" % info["containers"])
    vpn = any(RULE_VPN in m for m in msgs)
    el8 = info["el"] == 8 and "AlmaLinux" not in info["source"]
    return cls, vpn, el8, reasons


def load(path):
    files = sorted(glob.glob(os.path.join(path, "*", "survey.txt"))) or sorted(glob.glob(os.path.join(path, "*.txt")))
    hosts = []
    for f in files:
        name = os.path.basename(os.path.dirname(f)) if os.path.basename(f) == "survey.txt" else os.path.splitext(os.path.basename(f))[0]
        with open(f, encoding="utf-8", errors="replace") as fh:
            info = parse_survey(fh.read())
        cls, vpn, el8, reasons = classify(info)
        info.update(host=name, cls=cls, vpn=vpn, el8=el8, reasons=reasons,
                    blockers=sum(1 for lv, _ in info["flags"] if lv == "BLOCKER"),
                    highs=sum(1 for lv, _ in info["flags"] if lv == "HIGH"))
        hosts.append(info)
    return hosts


def plan(hosts, groups, batch):
    """金丝雀：每个类别（A/B/C，不含 VPN）挑一台 BLOCKER+HIGH 最少的。之后按 A→B→C 分批，VPN 机器放最后，D 不排入。
    同一 group 的机器不进同一批。"""
    todo = [h for h in hosts if h["cls"] != "D"]
    canaries = []
    for c in ("A", "B", "C"):
        cand = sorted((h for h in todo if h["cls"] == c and not h["vpn"]), key=lambda h: (h["blockers"], h["highs"], h["host"]))
        if cand:
            canaries.append(cand[0])
    rest = [h for h in todo if h not in canaries]
    rest.sort(key=lambda h: (h["vpn"], CLASS_ORDER[h["cls"]], h["blockers"] + h["highs"], h["host"]))
    waves = [canaries] if canaries else []
    for h in rest:
        g = groups.get(h["host"])
        placed = False
        for w in waves[1:]:
            if len(w) < batch and (not g or g not in {groups.get(x["host"]) for x in w}) and w[-1]["vpn"] == h["vpn"]:
                w.append(h)
                placed = True
                break
        if not placed:
            waves.append([h])
    return waves


def render(hosts, waves, groups):
    out = ["# Fleet survey summary", ""]
    cnt = {c: sum(1 for h in hosts if h["cls"] == c) for c in "ABCD"}
    out.append("共 %d 台：A 简单 %d / B 容器型 %d / C 定制型 %d / D 不原地 %d；VPN/隧道 %d；CentOS 8 源 %d" % (
        len(hosts), cnt["A"], cnt["B"], cnt["C"], cnt["D"], sum(h["vpn"] for h in hosts), sum(h["el8"] for h in hosts)))
    out += ["", "| 主机 | 系统 | 云 | 类 | BLOCKER | HIGH | 容器 | 标记 | 主要原因 |", "|---|---|---|---|---|---|---|---|---|"]
    for h in sorted(hosts, key=lambda h: (CLASS_ORDER[h["cls"]], h["host"])):
        tags = " ".join(t for t, on in (("VPN", h["vpn"]), ("EL8→convert", h["el8"]), ("no-v3", h["v3"] is False)) if on)
        out.append("| %s | %s | %s | %s | %d | %d | %d | %s | %s |" % (
            h["host"], h["source"][:40], h["cloud"], h["cls"], h["blockers"], h["highs"], h["containers"], tags, "; ".join(h["reasons"])[:90]))
    out += ["", "## 建议批次", ""]
    for i, w in enumerate(waves):
        title = "第 0 批（金丝雀，每类一台，全流程含最终重启测试）" if i == 0 and all(not h["vpn"] for h in w) else "第 %d 批" % i
        out.append("- **%s**：%s" % (title, ", ".join("%s(%s%s)" % (h["host"], h["cls"], ",VPN" if h["vpn"] else "") for h in w)))
    d = [h["host"] for h in hosts if h["cls"] == "D"]
    if d:
        out.append("- **不排入批次（D，建议新建机器迁移）**：%s" % ", ".join(d))
    out += ["", "规则：同一 group 不同批%s；VPN 机器最后做并提前准备控制台；EL8 机器先 convert-el8.sh。" % ("（已按 --groups 处理）" if groups else "（未提供 --groups）")]
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="目录：<host>/survey.txt 或 *.txt")
    ap.add_argument("--groups", help="CSV: host,group（同业务主备不放同一批）")
    ap.add_argument("--batch", type=int, default=5, help="每批最多几台（默认 5）")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    hosts = load(a.path)
    if not hosts:
        print("没有找到 survey 结果：%s" % a.path, file=sys.stderr)
        return 1
    groups = {}
    if a.groups:
        with open(a.groups, encoding="utf-8-sig", newline="") as f:
            for r in csv.DictReader(f):
                groups[(r.get("host") or "").strip()] = (r.get("group") or "").strip()
    waves = plan(hosts, groups, max(1, a.batch))
    if a.json:
        print(json.dumps({"hosts": [{k: v for k, v in h.items() if k != "flags"} for h in hosts],
                          "waves": [[h["host"] for h in w] for w in waves]}, ensure_ascii=False, indent=2))
    else:
        print(render(hosts, waves, groups))
    return 0


if __name__ == "__main__":
    sys.exit(main())
