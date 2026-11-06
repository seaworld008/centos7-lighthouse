#!/usr/bin/env python3
"""check_repo.py - repository self-check (run locally before committing; CI runs it too).

Checks:
  1. Skill structure: SKILL.md frontmatter (name == dir, description present, <=1024 chars), body < 500 lines,
     every scripts/ references/ assets/ path mentioned in SKILL.md exists, shell scripts have a shebang.
  2. Version consistency: .claude-plugin/plugin.json == marketplace.json (metadata + plugin entry) == latest CHANGELOG release.
  3. Field reports: front matter keys present and every report is listed in field-reports/README.md.
  4. Sensitive data in tracked text files: IPv4 addresses outside the documentation allow-list, private keys,
     cloud access keys, GitHub tokens, quoted passwords, e-mail addresses.
     Put `check_repo: allow` on a line to whitelist it deliberately.

Exit code = number of problems (0 = clean). Python 3.6+, no third-party deps.
"""
import ipaddress
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
problems = []


def bad(msg):
    problems.append(msg)
    print("  ✗ " + msg)


def ok(msg):
    print("  ✓ " + msg)


def rel(p):
    return os.path.relpath(p, ROOT).replace("\\", "/")


def tracked_files():
    try:
        out = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, stderr=subprocess.DEVNULL)
        files = [f for f in out.decode("utf-8", "replace").splitlines() if f]
        if files:
            return files
    except Exception:
        pass
    skip = {".git", "_private", "__pycache__", "fleet", "node_modules"}
    res = []
    for d, dirs, fs in os.walk(ROOT):
        dirs[:] = [x for x in dirs if x not in skip]
        for f in fs:
            res.append(rel(os.path.join(d, f)))
    return res


def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- 1. skills
print("[1] skills")
skills_dir = os.path.join(ROOT, "skills")
for name in sorted(os.listdir(skills_dir)):
    sd = os.path.join(skills_dir, name)
    if not os.path.isdir(sd):
        continue
    sk = rel(os.path.join(sd, "SKILL.md"))
    if not os.path.exists(os.path.join(ROOT, sk)):
        bad("%s missing" % sk)
        continue
    text = read(sk)
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not m:
        bad("%s: missing YAML frontmatter" % sk)
        continue
    fm, body = m.group(1), m.group(2)
    fname = re.search(r"^name:\s*(.+)$", fm, re.M)
    desc = re.search(r"^description:\s*(.+)$", fm, re.M)
    if not fname or fname.group(1).strip() != name:
        bad("%s: frontmatter name must equal directory name '%s'" % (sk, name))
    if not desc or not desc.group(1).strip():
        bad("%s: description missing" % sk)
    elif len(desc.group(1).strip()) > 1024:
        bad("%s: description longer than 1024 chars" % sk)
    n = body.count("\n")
    (bad if n >= 500 else ok)("%s body %d lines (limit 500)" % (sk, n))
    missing = [p for p in sorted(set(re.findall(r"\b((?:scripts|references|assets)/[\w.\-]+)", text)))
               if not os.path.exists(os.path.join(sd, p))]
    for p in missing:
        bad("%s references %s which does not exist" % (sk, p))
    if not missing:
        ok("%s: all referenced scripts/references/assets exist" % name)
    for f in sorted(os.listdir(os.path.join(sd, "scripts"))) if os.path.isdir(os.path.join(sd, "scripts")) else []:
        if f.endswith((".sh", ".py")):
            first = read(rel(os.path.join(sd, "scripts", f))).split("\n", 1)[0]
            if not first.startswith("#!"):
                bad("%s/scripts/%s: missing shebang" % (name, f))

# ---------------------------------------------------------------- 2. versions
print("[2] versions")
try:
    pj = json.loads(read(".claude-plugin/plugin.json"))
    mj = json.loads(read(".claude-plugin/marketplace.json"))
    vers = {"plugin.json": pj.get("version"), "marketplace.metadata": mj.get("metadata", {}).get("version")}
    for p in mj.get("plugins", []):
        vers["marketplace.plugins[%s]" % p.get("name")] = p.get("version")
    cl = re.findall(r"^## \[(\d+\.\d+\.\d+)\]", read("CHANGELOG.md"), re.M)
    vers["CHANGELOG latest"] = cl[0] if cl else None
    if len(set(vers.values())) == 1 and None not in vers.values():
        ok("all versions = %s" % pj["version"])
    else:
        bad("version mismatch: %s" % vers)
except Exception as e:  # noqa
    bad("version check failed: %s" % e)

# ---------------------------------------------------------------- 3. field reports
print("[3] field reports")
fr = os.path.join(ROOT, "field-reports")
if os.path.isdir(fr):
    index = read("field-reports/README.md")
    for f in sorted(os.listdir(fr)):
        if not f.endswith(".md") or f in ("README.md", "TEMPLATE.md"):
            continue
        t = read("field-reports/" + f)
        fmm = re.match(r"^---\n(.*?)\n---", t, re.S)
        keys = set(re.findall(r"^(\w+):", fmm.group(1), re.M)) if fmm else set()
        need = {"date", "cloud", "profile", "source_version", "target_version", "result"}
        if need - keys:
            bad("field-reports/%s: front matter missing %s" % (f, sorted(need - keys)))
        if f not in index:
            bad("field-reports/%s not listed in field-reports/README.md" % f)
    ok("field reports checked")

# ---------------------------------------------------------------- 4. sensitive data
print("[4] sensitive data")
ALLOW_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/24",        # documentation examples used in this repo
    "127.0.0.0/8", "0.0.0.0/32", "169.254.169.254/32",
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",  # RFC 5737 documentation ranges
)]
PATTERNS = [
    ("private key", re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Aliyun AccessKey", re.compile(r"\bLTAI[0-9A-Za-z]{12,}\b")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("quoted password/secret", re.compile(r"(?i)\b(password|passwd|pwd|secret|token|secret_key)\b\s*[:=]\s*[\"'][^\"'\s$]{6,}[\"']")),
    ("e-mail address", re.compile(r"\b[\w.+-]+@(?!example\.(?:com|org)\b)(?!users\.noreply\.github\.com\b)[\w-]+\.[\w.-]+\b")),
]
IPV4 = re.compile(r"(?<![\w.])((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})(?![\w.])")
TEXT_EXT = (".md", ".sh", ".py", ".json", ".yml", ".yaml", ".csv", ".txt", ".conf", ".toml", "")
SELF = "tools/check_repo.py"
hits = 0
for f in tracked_files():
    if f == SELF or not f.endswith(TEXT_EXT) or f.startswith(".git/"):
        continue
    try:
        lines = read(f).splitlines()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        continue
    for i, line in enumerate(lines, 1):
        if "check_repo: allow" in line:
            continue
        for label, rx in PATTERNS:
            if rx.search(line):
                bad("%s:%d possible %s" % (f, i, label)); hits += 1
        for ip in IPV4.findall(line):
            try:
                a = ipaddress.ip_address(ip)
            except ValueError:
                continue
            if not any(a in n for n in ALLOW_NETS):
                bad("%s:%d IPv4 %s outside allow-list (use 10.0.0.x / RFC5737, or mark 'check_repo: allow')" % (f, i, ip)); hits += 1
if not hits:
    ok("no sensitive data patterns found")

print("\n%s: %d problem(s)" % ("FAIL" if problems else "OK", len(problems)))
sys.exit(min(len(problems), 100))
