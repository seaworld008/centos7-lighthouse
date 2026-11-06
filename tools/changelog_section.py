#!/usr/bin/env python3
"""changelog_section.py VERSION - 打印 CHANGELOG.md 中 `## [VERSION]` 一节（不含标题），并附上安装说明。Release 工作流用它生成发布说明。"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = """
---
### 安装 / Install
```
/plugin install centos7-almalinux-upgrade --marketplace seaworld008/centos7-lighthouse
```
完整变更见 [CHANGELOG](https://github.com/seaworld008/centos7-lighthouse/blob/main/CHANGELOG.md)。**升级前请先做整机快照，并在非关键机器上先试。**
"""


def section(text, version):
    m = re.search(r"^## \[%s\][^\n]*\n(.*?)(?=^## \[|\Z)" % re.escape(version), text, re.S | re.M)
    if not m:
        return None
    # 相对链接在 Release 页面上打不开：转成仓库内的绝对链接
    return re.sub(r"\]\((?!https?://|#|mailto:)([^)]+)\)", r"](https://github.com/seaworld008/centos7-lighthouse/blob/main/\1)", m.group(1).strip())


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as f:
        body = section(f.read(), argv[1])
    if not body:
        print("CHANGELOG.md 里没有 [%s]" % argv[1], file=sys.stderr)
        return 1
    sys.stdout.write(body + "\n" + INSTALL)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
