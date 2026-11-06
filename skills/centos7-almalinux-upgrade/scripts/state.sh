#!/bin/bash
# state.sh - 输出当前"业务状态快照"（TSV），用于升级前基线和每跳之后对比
# 用法: bash state.sh > state.tsv
# 行格式:
#   os      <release>
#   unit    <service>            （当前 active 的常驻服务）
#   port    <proto>/<port>       （监听端口，不含地址，便于跨版本对比）
#   ctr     <name>  <state>      （docker 容器）
#   http    <url>   <code>       （nginx 各 server_name 的本地 https/http 状态码 + 各 TCP 端口 http 探测）
#   kube    nodes   <Ready数量>
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
printf "os\t%s\n" "$(cat /etc/redhat-release 2>/dev/null)"

systemctl list-units --type=service --state=active --no-legend --no-pager 2>/dev/null \
  | awk '{print $1}' | sed 's/^●//' \
  | grep -vE "^(user@|user-runtime-dir@|session-|run-|leapp|systemd-|dracut|kmod|plymouth|getty@|serial-getty@|lvm2-pvscan@|initrd|sshd-keygen@|rhel-|cloud-|kdump|import-state|selinux|ldconfig|dnf-makecache|NetworkManager-wait-online|nis-domainname|loadmodules|network.service|rpc-statd|var-lib|blk-availability|microcode|readonly-root)" \
  | sort -u | sed 's/^/unit\t/'

ss -tlnu 2>/dev/null | tail -n +2 | awk '{split($5,a,":"); p=a[length(a)]; print "port\t" $1 "/" p}' | sort -u   # EL7 的 ss 没有 -H

if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null | sort | sed 's/^/ctr\t/'
fi

# nginx 虚拟主机探测
NG=$(pgrep -a nginx 2>/dev/null | grep master | grep -oE "/[^ ]*nginx( |$)" | head -1 | tr -d ' ')
[ -z "$NG" ] && command -v nginx >/dev/null 2>&1 && NG=$(command -v nginx)
if [ -n "$NG" ]; then
  $NG -T 2>/dev/null | grep -E "^\s*server_name\s" | sed -E 's/^\s*server_name\s+//; s/;.*//' | tr ' ' '\n' \
    | grep -vE "^(_|localhost|\*.*|~.*|)$" | sort -u | while read -r h; do
      for sch in https http; do
        port=443; [ $sch = http ] && port=80
        code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' --resolve "$h:$port:127.0.0.1" "$sch://$h/" 2>/dev/null)
        printf "http\t%s://%s/\t%s\n" "$sch" "$h" "${code:-000}"
      done
    done
fi
# 其它 TCP 端口的 http 探测（非 http 服务稳定返回 000，作为基线照样可比）
SSHP=$(sshd -T 2>/dev/null | awk '/^port /{print $2}')
ss -tln 2>/dev/null | tail -n +2 | awk '{split($4,a,":"); print a[length(a)]}' | sort -un | while read -r p; do
  case "$p" in 22|25|80|443|111|323|10050) continue;; esac
  echo " $SSHP " | grep -q " $p " && continue
  code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "http://127.0.0.1:$p/" 2>/dev/null)
  printf "http\thttp://127.0.0.1:%s/\t%s\n" "$p" "${code:-000}"
done

if command -v kubectl >/dev/null 2>&1 && [ -s /root/.kube/config ]; then
  n=$(timeout 20 kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/' | wc -l)
  printf "kube\tnodes\t%s\n" "$n"
fi
