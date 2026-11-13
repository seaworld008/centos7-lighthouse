#!/bin/bash
# known-hosts-fill.sh - 升级到 EL10 后，给 known_hosts 里"只记录了一种主机密钥类型"的主机补齐其它类型
#
# 背景：EL10 的 crypto-policies 在 ssh_config 里显式设置了 HostKeyAlgorithms，OpenSSH 因此不再
# "优先使用 known_hosts 里已记录的密钥类型"，而是直接协商 ssh-ed25519。known_hosts 里只有 ECDSA/RSA
# 记录的主机会报 "Host key verification failed"（BatchMode / CI 发布任务直接失败）。
#
# 做法（不盲信新密钥）：用已记录、已信任的密钥类型连上去（HostKeyAlgorithms=<已记录类型>），在这条
# 已验证身份的连接里读取对方 /etc/ssh/ssh_host_*_key.pub，把缺的类型追加到 known_hosts。
# 需要能免密登录目标（CI 主机通常就是这样）；连不上的只报告，不改。
#
# 用法：bash known-hosts-fill.sh [known_hosts 路径，默认 ~/.ssh/known_hosts]
# 环境变量：LOGIN_USER（默认 root）、EXTRA_PORTS（记录为 22 端口但 22 不通时再试的端口，默认 "10015"）
# 注意：验证时加 -o ControlPath=none —— ControlMaster/ControlPersist 复用的旧连接会跳过主机密钥检查，造成"已修好"的假象。
set -u
KH=${1:-$HOME/.ssh/known_hosts}
U=${LOGIN_USER:-root}
EXTRA=${EXTRA_PORTS:-10015}
[ -s "$KH" ] || { echo "无 $KH"; exit 0; }
cp -a "$KH" "$KH.bak-osup-$(date +%Y%m%d%H%M%S)"
before=$(wc -l < "$KH")
ERR=$(mktemp)
awk '$1 !~ /^\|/ && $1 !~ /^#/ && NF >= 3 {print $1, $2}' "$KH" | sort -u | while read -r hosts type; do
  h=${hosts%%,*}; port=22
  case "$h" in \[*\]:*) port=${h##*:}; h=${h#[}; h=${h%%]*};; esac
  ports=$port; [ "$port" = 22 ] && ports="22 $EXTRA"
  rc=1; keys=""
  for pp in $ports; do
    keys=$(timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=6 -o ControlPath=none \
           -o HostKeyAlgorithms="$type" -o StrictHostKeyChecking=yes -p "$pp" "$U@$h" \
           'cat /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub 2>/dev/null' 2>"$ERR"); rc=$?
    [ $rc = 0 ] && { port=$pp; break; }
  done
  if [ $rc != 0 ]; then
    e=$(cat "$ERR")
    case "$e" in
      *"Permission denied"*) st=auth-denied;;
      *"verification failed"*|*"IDENTIFICATION HAS CHANGED"*) st="KEY-MISMATCH（已记录的密钥与对方不符，需人工核实）";;
      *) st=unreachable;;
    esac
    printf '%-24s %-6s %s\n' "$h" "$port" "$st"; continue
  fi
  added=0
  while read -r ktype kval _; do
    [ -n "${kval:-}" ] || continue
    grep -qF "$kval" "$KH" && continue
    echo "$hosts $ktype $kval" >> "$KH"; added=$((added+1))
  done <<< "$keys"
  printf '%-24s %-6s added=%s\n' "$h" "$port" "$added"
done
rm -f "$ERR"
echo "known_hosts: $before -> $(wc -l < "$KH") 行（备份 $KH.bak-osup-*）"
