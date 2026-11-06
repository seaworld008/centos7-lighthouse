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

# nginx 虚拟主机探测：宿主机 nginx + 容器里的 nginx/openresty/tengine（docker-proxy 映射到本机 80/443）
NG=$(pgrep -a nginx 2>/dev/null | grep master | grep -oE "/[^ ]*nginx( |$)" | head -1 | tr -d ' ')
[ -n "$NG" ] && [ ! -x "$NG" ] && NG=""          # 容器里的 nginx 进程，路径在宿主机上不存在
[ -z "$NG" ] && command -v nginx >/dev/null 2>&1 && NG=$(command -v nginx)
{
  [ -n "$NG" ] && $NG -T 2>/dev/null
  if command -v docker >/dev/null 2>&1; then
    docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -iE "nginx|openresty|tengine" | awk '{print $1}' | while read -r c; do
      # 老 nginx（<1.9.2）没有 -T：退回到直接读容器挂载点和常见配置目录里的 *.conf
      dests=$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$c" 2>/dev/null)
      docker exec "$c" sh -c "nginx -T 2>/dev/null || openresty -T 2>/dev/null || find $dests /etc/nginx /usr/local/openresty/nginx/conf /usr/local/nginx/conf /usr/servers/nginx/conf -name '*.conf' -type f -exec cat {} + 2>/dev/null" 2>/dev/null
    done
  fi
} | grep -E "^\s*server_name\s" | sed -E 's/^\s*server_name\s+//; s/;.*//' | tr ' ' '\n' \
  | grep -vE "^(_|localhost|\*.*|~.*|)$" | sort -u | while read -r h; do
    for sch in https http; do
      port=443; [ $sch = http ] && port=80
      code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' --resolve "$h:$port:127.0.0.1" "$sch://$h/" 2>/dev/null)
      printf "http\t%s://%s/\t%s\n" "$sch" "$h" "${code:-000}"
    done
  done
# 所有 TCP 端口按 IP 做 http 探测（443 用 https；非 http 服务稳定返回 000，作为基线照样可比）
SSHP=$(sshd -T 2>/dev/null | awk '/^port /{print $2}')
ss -tln 2>/dev/null | tail -n +2 | awk '{split($4,a,":"); print a[length(a)]}' | sort -un | while read -r p; do
  case "$p" in 22|25|111|323|10050) continue;; esac
  echo " $SSHP " | grep -q " $p " && continue
  sch=http; [ "$p" = 443 ] || [ "$p" = 8443 ] && sch=https
  code=$(curl -sk -o /dev/null -m 4 -w '%{http_code}' "$sch://127.0.0.1:$p/" 2>/dev/null)
  printf "http\t%s://127.0.0.1:%s/\t%s\n" "$sch" "$p" "${code:-000}"
done

if command -v kubectl >/dev/null 2>&1 && [ -s /root/.kube/config ]; then
  n=$(timeout 20 kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/' | wc -l)
  printf "kube\tnodes\t%s\n" "$n"
fi
