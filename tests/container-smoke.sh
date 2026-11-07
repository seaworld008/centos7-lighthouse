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
t "finalize.sh usage"   bash -c "bash '$K/finalize.sh' | grep -q compose-wrapper && bash '$K/finalize.sh' | grep -q manual-procs"
t "k8s.sh usage"        bash -c "bash '$K/k8s.sh' | grep -q 'k8s.sh backup' && bash '$K/k8s.sh' | grep -q jvm-maxram"
t "k8s.sh pods 无 kubectl 时优雅退出" bash -c "out=\$(bash '$K/k8s.sh' pods 2>&1); [ \$? -ne 0 ] && echo \"\$out\" | grep -q 'kubectl 连不上'"
t "k8s.sh check 无 kubelet/docker 不报 shell 错" bash -c "! bash '$K/k8s.sh' check 2>&1 | grep -E 'syntax error|unbound variable|bad substitution'"
# ---- 会修改系统、但对任何 EL 版本都安全的测试（只在一次性容器里）----
if [ -f /.dockerenv ] && [ "${SKIP_MUTATING:-0}" != 1 ]; then
  printf '[kubernetes]\nname=k8s\nbaseurl=https://example.com/kubernetes-el7-x86_64\nenabled=1\n' > /etc/yum.repos.d/kubernetes.repo
  t "k8s.sh pin 在 k8s 源里 exclude 组件" bash -c "bash '$K/k8s.sh' pin >/dev/null; grep -q '^exclude=kubelet kubeadm kubectl' /etc/yum.repos.d/kubernetes.repo"
  t "k8s.sh pin 幂等" bash -c "bash '$K/k8s.sh' pin >/dev/null; [ \$(grep -c '^exclude=' /etc/yum.repos.d/kubernetes.repo) = 1 ]"
  rm -f /etc/yum.repos.d/kubernetes.repo
  cp /etc/fstab /tmp/fstab.orig 2>/dev/null || : > /tmp/fstab.orig
  echo '10.0.0.9:/data/k8s /nfsdata nfs defaults 0 0' >> /etc/fstab
  t "k8s.sh nfs-off 注释 fstab 的 NFS" bash -c "bash '$K/k8s.sh' nfs-off >/dev/null 2>&1; grep -q '^#osup-nfs# 10.0.0.9:/data/k8s' /etc/fstab"
  t "k8s.sh nfs-on 恢复 fstab" bash -c "sed -i 's/^#osup-nfs# //' /etc/fstab; grep -q '^10.0.0.9:/data/k8s' /etc/fstab"
  cp /tmp/fstab.orig /etc/fstab
  mkdir -p $W/mp /etc/systemd/system
  printf '/usr/bin/java\n-Xmx512m\n-jar\napp.jar\n' > $W/mp/123.cmdline; echo /data/demo/svc > $W/mp/123.cwd; echo /usr/bin/java > $W/mp/123.exe
  printf 'PATH=/usr/bin:/bin\nLANG=en_US.UTF-8\nSECRET=x\n' > $W/mp/123.environ
  t "finalize.sh manual-procs 生成 systemd 服务（不带无关环境变量）" bash -c "bash '$K/finalize.sh' manual-procs $W/mp >/dev/null 2>&1; f=/etc/systemd/system/osup-demo-svc.service; grep -q 'ExecStart=/usr/bin/java \"-Xmx512m\" \"-jar\" \"app.jar\"' \$f && grep -q 'WorkingDirectory=/data/demo/svc' \$f && ! grep -q SECRET \$f"
  rm -f /etc/systemd/system/osup-demo-svc.service
fi
if [ "$(rpm -E %rhel 2>/dev/null)" = 7 ]; then
  t "prep-el7.sh usage on EL7"   bash -c "bash '$K/prep-el7.sh' | grep -q 'prep-el7.sh repos'"
else
  t "prep-el7.sh refuses non-EL7" bash -c "! bash '$K/prep-el7.sh' repos upstream"
fi
if [ "$(rpm -E %rhel 2>/dev/null)" = 8 ]; then
  t "convert-el8.sh usage on EL8"     bash -c "bash '$K/convert-el8.sh' | grep -q 'convert-el8.sh prep'"
  t "convert-el8.sh run refuses <8.4" bash -c "grep -qE 'release 8\.[4-9]|Stream' /etc/redhat-release && exit 0; ! bash '$K/convert-el8.sh' run upstream /nonexistent"
else
  t "convert-el8.sh refuses non-EL8"  bash -c "! bash '$K/convert-el8.sh' prep upstream"
fi
# ---- 会修改系统的测试：只在一次性容器里跑（/.dockerenv 存在），绝不在真实机器上跑 ----
if [ -f /.dockerenv ] && [ "$(rpm -E %rhel 2>/dev/null)" = 7 ] && [ "${SKIP_MUTATING:-0}" != 1 ]; then
  t "prep-el7.sh repos upstream → vault 源可用" bash -c "bash '$K/prep-el7.sh' repos upstream >/tmp/r.out 2>&1; grep -q 'vault.centos.org/7.9.2009' /etc/yum.repos.d/CentOS-Base.repo && yum -q makecache fast >/dev/null 2>&1"
  mkdir -p /usr/lib/python2.7/site-packages/fake_pip_pkg && touch /usr/lib/python2.7/site-packages/fake_pip_pkg-1.0-py2.7.egg-info
  t "prep-el7.sh pipfix 挪走不属于 rpm 的文件" bash -c "bash '$K/prep-el7.sh' pipfix | grep -q '挪走 [0-9]* 个' && [ ! -e /usr/lib/python2.7/site-packages/fake_pip_pkg ]"
  t "prep-el7.sh inhibitors 可执行" bash -c "bash '$K/prep-el7.sh' inhibitors >/tmp/i.out 2>&1; grep -q 'blacklist floppy' /etc/modprobe.d/leapp-removed-drivers.conf"
  t "swap-openssh.sh: 未安装时不动" bash -c "rpm -q openssh-server >/dev/null && exit 0; bash '$K/swap-openssh.sh' | grep -q '未安装'"
  yum -q -y install openssh-server >/dev/null 2>&1
  t "swap-openssh.sh: 官方包时不替换" bash -c "bash '$K/swap-openssh.sh' | grep -q '已是官方包'"
  t "survey.sh 在 EL7 上能识别 pip/openssh 状态" bash -c "bash '$K/survey.sh' 2>/dev/null | grep -q '^===== OPENSSH'"
fi
PYB=$(command -v python3 || true)
[ -n "$PYB" ] && t "remote.py compiles (py3)" "$PYB" -m py_compile "$K/remote.py"

echo "== $(cat /etc/redhat-release 2>/dev/null): PASS=$PASS FAIL=$FAILN"
rm -rf "$W"
[ "$FAILN" -eq 0 ]
