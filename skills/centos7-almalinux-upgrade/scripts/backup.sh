#!/bin/bash
# backup.sh - 升级前备份关键配置 + 记录业务基线（不替代云快照！）
# 用法: bash backup.sh [备份根目录]     默认优先用非系统盘（/data 等），输出最后一行 BACKUP_DIR=...
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HERE=$(cd "$(dirname "$0")" && pwd)

pick_base() {
  for d in /data /data1 /home /opt /var/tmp; do
    [ -d "$d" ] || continue
    [ "$(df -P "$d" | awk 'NR==2{print $6}')" = "/" ] && continue       # 跳过和系统盘同一个文件系统的
    [ "$(df -Pm "$d" | awk 'NR==2{print $4}')" -gt 4000 ] && { echo "$d"; return; }
  done
  echo "/var/tmp"   # 只有系统盘时只能放这里（云快照才是真正的回滚手段）
}
BASE=${1:-$(pick_base)}
B="$BASE/os-upgrade-backup/$(date +%Y%m%d-%H%M)"
mkdir -p "$B" && cd "$B" || exit 1
echo "备份到 $B"

tar czf etc.tgz /etc 2>/dev/null
# 构建缓存可重新下载、快照里也有：CI/构建机上动辄几十 GB（真实案例：.m2 17G + .npm 16G），不打包
tar czf root-home.tgz --exclude=/root/.cache --exclude='/root/*.hprof' --exclude='/root/*.tar.gz' --exclude=/root/os-upgrade-kit \
  --exclude=/root/.m2/repository --exclude=/root/.npm --exclude=/root/.pnpm-store --exclude=/root/.npminstall_tarball \
  --exclude=/root/.gradle/caches --exclude=/root/.yarn/cache --exclude=/root/go/pkg /root 2>/dev/null
tar czf var-spool-cron.tgz /var/spool/cron 2>/dev/null
# /opt /usr/local 以及运行中非 rpm 程序所在目录（限 2GB 以内的目录，避免把数据打进去）
DIRS="/opt /usr/local"
for pid in $(ls /proc | grep -E '^[0-9]+$'); do readlink /proc/$pid/exe 2>/dev/null; done | sort -u | while read -r exe; do
  [ -f "$exe" ] && ! rpm -qf "$exe" >/dev/null 2>&1 && echo "$exe"; done | grep -vE "^/(var/lib/docker|var/lib/containerd|usr/local|opt)/" \
  | awk -F/ 'NF>2{print "/"$2"/"$3}' | sort -u > appdirs.txt
for d in $DIRS $(cat appdirs.txt); do
  [ -d "$d" ] || continue
  sz=$(du -sm "$d" 2>/dev/null | awk '{print $1}')
  if [ "${sz:-0}" -lt 2048 ]; then tar czf "dir$(echo "$d" | tr / _).tgz" "$d" 2>/dev/null; else echo "跳过大目录 $d (${sz}MB)，只记录清单"; find "$d" -maxdepth 2 > "dir$(echo "$d" | tr / _).list"; fi
done

rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{VENDOR}\n' | sort > rpm-list.tsv
systemctl list-unit-files --no-pager > unit-files.txt
systemctl list-units --type=service --no-pager > units.txt
ip addr > ip-addr.txt; ip route > ip-route.txt; cp /etc/resolv.conf . 2>/dev/null
ss -tulnp > ss.txt; iptables-save > iptables.txt 2>/dev/null; nft list ruleset > nft.txt 2>/dev/null
for u in $(cut -d: -f1 /etc/passwd); do crontab -l -u "$u" 2>/dev/null | sed "s/^/[$u] /"; done > crontabs.txt
cp -a /etc/sysconfig/network-scripts network-scripts 2>/dev/null
[ -d /etc/NetworkManager/system-connections ] && cp -a /etc/NetworkManager/system-connections nm-connections

if command -v docker >/dev/null 2>&1; then
  docker ps -a --no-trunc > docker-ps.txt 2>&1
  for c in $(docker ps -aq); do docker inspect "$c"; done > docker-inspect.json 2>/dev/null
  docker images > docker-images.txt 2>&1
  cp -a /etc/docker docker-etc 2>/dev/null
  # 各 compose 项目文件
  for c in $(docker ps -aq); do docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c"; done | sort -u | grep . | while read -r d; do
    mkdir -p "compose$(echo "$d" | tr / _)"; cp -a "$d"/*.y*ml "$d"/.env "compose$(echo "$d" | tr / _)/" 2>/dev/null; done
fi
[ -d /root/.kube ] && cp -a /root/.kube kube
for b in kubectl helm docker-compose; do p=$(command -v $b) && cp -a "$p" "bin-$b" 2>/dev/null; done
for n in $(pgrep -a nginx 2>/dev/null | grep master | grep -oE "/[^ ]*nginx( |$)" | sort -u); do $n -V > nginx-V.txt 2>&1; $n -T > nginx-T.txt 2>/dev/null; done
command -v php >/dev/null && { php -m > php-m.txt; php -i > php-i.txt; } 2>/dev/null

# 手工从 SSH 会话启动的常驻进程（nohup java -jar ... &）：重启后不会自己起来，升级后用 finalize.sh manual-procs 恢复（真实踩坑：5 个宿主机 Java 程序）
for pid in $(ps -eo pid=); do
  cg=$(cat /proc/$pid/cgroup 2>/dev/null) || continue
  echo "$cg" | grep -q "session-[0-9]*\.scope" || continue
  echo "$cg" | grep -qE "docker|kubepods|containerd" && continue
  comm=$(cat /proc/$pid/comm 2>/dev/null)
  case "$comm" in bash|sh|zsh|sshd|sudo|su|screen|tmux*|ps|grep|sleep|tail|less|vim|vi|top|backup.sh|state.sh|systemd*|sftp-server|login|crond|timeout) continue;; esac
  ss -lntp 2>/dev/null | grep -q "pid=$pid," || continue   # 只记录在监听端口的（真正的服务）
  mkdir -p manual-procs
  tr '\0' '\n' < /proc/$pid/cmdline > manual-procs/$pid.cmdline; readlink /proc/$pid/cwd > manual-procs/$pid.cwd
  readlink /proc/$pid/exe > manual-procs/$pid.exe; tr '\0' '\n' < /proc/$pid/environ > manual-procs/$pid.environ 2>/dev/null
  echo "手工启动的服务进程 pid=$pid $(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-100)"
done

bash "$HERE/state.sh" > baseline.tsv 2>/dev/null
echo "---- 业务基线 baseline.tsv ----"; cat baseline.tsv
echo; du -sh "$B"
echo "BACKUP_DIR=$B"
