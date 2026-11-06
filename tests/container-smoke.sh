#!/bin/bash
# container-smoke.sh - 在 EL7~EL10 容器里冒烟测试工具包（只测"能跑、输出结构对、只读脚本不出错、对比逻辑正确"）
#
# 两种用法：
#   bash tests/container-smoke.sh                 # 本机有 docker：依次在 centos:7 almalinux:8 almalinux:9 almalinux:10 中运行
#   bash tests/container-smoke.sh --inside        # 已在目标容器/机器内（CI 用），仓库挂载在 /repo
# 容器里没有 systemd/sshd/docker，这些检查项会优雅跳过——这正是要验证的"缺命令时降级"。
set -u
IMAGES=${IMAGES:-"centos:7 almalinux:8 almalinux:9 almalinux:10"}

if [ "${1:-}" != "--inside" ]; then
  REPO=$(cd "$(dirname "$0")/.." && pwd)
  rc=0
  for img in $IMAGES; do
    echo "################ $img ################"
    docker run --rm -v "$REPO:/repo:ro" "$img" bash /repo/tests/container-smoke.sh --inside || rc=1
  done
  exit $rc
fi

S=${S:-/repo/skills/centos7-almalinux-upgrade/scripts}
PASS=0; FAILN=0
t() { local name=$1; shift; if "$@" >/tmp/t.out 2>&1; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name"; sed 's/^/      | /' /tmp/t.out | tail -15; FAILN=$((FAILN+1)); fi; }
W=$(mktemp -d); cp -r "$S" "$W/kit"; K=$W/kit     # 只读挂载 → 复制一份执行
echo "env: $(cat /etc/redhat-release 2>/dev/null) bash=$BASH_VERSION python=$(command -v python3 || command -v python || echo none)"

for f in "$K"/*.sh; do t "bash -n $(basename "$f")" bash -n "$f"; done

t "survey.sh runs and prints RISK FLAGS" bash -c "bash '$K/survey.sh' 2>/dev/null | tee $W/survey.txt | grep -q '^################ RISK FLAGS'"
t "survey.sh has all sections"        bash -c "for s in OS CPU 'MEMORY/DISK' PACKAGES OPENSSH SERVICES NETWORK 'DOCKER/CONTAINERS' KUBERNETES 'RUNTIMES/DATABASES'; do grep -q \"^===== \$s\" $W/survey.txt || { echo missing \$s; exit 1; }; done"
t "survey.sh detects el version"      bash -c "grep -qE 'el=(7|8|9|10)\b' $W/survey.txt"
t "survey.sh no shell errors"         bash -c "! bash '$K/survey.sh' 2>&1 >/dev/null | grep -E 'syntax error|unbound variable|integer expression expected|bad substitution|command not found: \\['"

t "state.sh outputs os line"          bash -c "bash '$K/state.sh' > $W/base.tsv 2>/dev/null; grep -qP '^os\t' $W/base.tsv"
mkdir -p "$W/bk"; cp "$W/base.tsv" "$W/bk/baseline.tsv"
t "verify.sh: identical state -> exit 0" bash "$K/verify.sh" "$W/bk" --wait 0
printf 'port\ttcp/65000\nctr\tghost\trunning\nunit\tntpd.service\nport\tudp/68\n' >> "$W/bk/baseline.tsv"
t "verify.sh: detects planted regressions" bash -c "out=\$(bash '$K/verify.sh' '$W/bk' --wait 0); rc=\$?; echo \"\$out\"; [ \$rc -eq 2 ] && echo \"\$out\" | grep -q 'FAIL  端口 tcp/65000' && echo \"\$out\" | grep -q 'FAIL  容器 ghost' && echo \"\$out\" | grep -q 'WARN  端口 udp/68'"

# hop.sh report：用伪造的 leapp 报告测试 python 解析（EL7 上走 python2 分支）
export LEAPP_LOG_DIR=$W/leapp; mkdir -p "$LEAPP_LOG_DIR" && cat > "$LEAPP_LOG_DIR/leapp-report.json" <<'EOF'
{"entries":[{"title":"Fake inhibitor","summary":"fake summary","severity":"high","groups":["inhibitor"],"detail":{"remediations":[{"type":"command","context":["echo","fix"]}]}},
{"title":"Packages not signed by Red Hat found on the system","summary":"The following packages:\n- foo\n- bar","severity":"high","groups":[]}]}
EOF
printf '[remove_pam_pkcs11_module_check]\n# confirm = \n' > "$LEAPP_LOG_DIR/answerfile"
: > "$LEAPP_LOG_DIR/leapp-preupgrade.log"
t "hop.sh report parses leapp json" bash -c "bash '$K/hop.sh' report 2>&1 | tee /dev/stderr | grep -q '\\[X\\] Fake inhibitor' && bash '$K/hop.sh' report 2>&1 | grep -q 'echo fix'"
unset LEAPP_LOG_DIR

t "hop.sh usage"        bash -c "bash '$K/hop.sh' | grep -q 'hop.sh prep'"
t "finalize.sh usage"   bash -c "bash '$K/finalize.sh' | grep -q compose-wrapper"
if [ "$(rpm -E %rhel 2>/dev/null)" = 7 ]; then
  t "prep-el7.sh usage on EL7"   bash -c "bash '$K/prep-el7.sh' | grep -q 'prep-el7.sh repos'"
else
  t "prep-el7.sh refuses non-EL7" bash -c "! bash '$K/prep-el7.sh' repos upstream"
fi
PYB=$(command -v python3 || true)
[ -n "$PYB" ] && t "remote.py compiles (py3)" "$PYB" -m py_compile "$K/remote.py"

echo "== $(cat /etc/redhat-release 2>/dev/null): PASS=$PASS FAIL=$FAILN"
rm -rf "$W"
[ "$FAILN" -eq 0 ]
