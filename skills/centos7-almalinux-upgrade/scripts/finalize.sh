#!/bin/bash
# finalize.sh - 到达 EL10 后的收尾/现代化工具（按需选用，每个子命令独立）
#
#   bash finalize.sh compose-wrapper          docker-compose v1 → 转发到 "docker compose" 的包装脚本（原文件备份）
#   bash finalize.sh kubectl [auto|1.30]      kubectl 换成 pkgs.k8s.io 源、与集群同 minor 版本（auto=按 kubeconfig 集群版本）
#   bash finalize.sh helm                     helm 升级到最新 v3（sha256 校验）
#   bash finalize.sh postfix-lmdb             postfix 的 hash:/btree: 表改 lmdb:（EL10 无 libdb）并重建
#   bash finalize.sh nginx-repo               添加 nginx.org 官方 stable 源并安装 nginx（不改配置、不启动）
#   bash finalize.sh cgroupv1-shim <compose目录>  给需要 cgroup v1 内存文件的老应用挂只读兼容文件并重建容器
#   bash finalize.sh iptables-legacy         加载并持久化 legacy iptables 表模块（容器内用 iptables-legacy 的镜像，如 wg-easy）
#   bash finalize.sh redis-valkey            redis → valkey（EL10 无 redis）：迁移 dump/aof、启用 valkey、redis-cli 兼容链接
#   bash finalize.sh manual-procs <DIR>      把升级前手工启动的进程（backup.sh 记录在 <BACKUP>/manual-procs）生成 systemd 服务
#   bash finalize.sh sysv-units              为仍靠 SysV init 脚本启动的服务生成原生 systemd unit（防止将来 systemd 去掉 sysv 支持）
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
K=/root/os-upgrade-kit/bak; mkdir -p $K
MIR=${MIRROR:-https://mirrors.aliyun.com}   # 环境变量 MIRROR=upstream 表示用官方源

case "$1" in
compose-wrapper)
  f=$(command -v docker-compose)
  if [ -n "$f" ] && ! grep -q "exec docker compose" "$f" 2>/dev/null; then
    v=$("$f" version --short 2>/dev/null); case "$v" in 1.*) cp -a "$f" "$K/docker-compose-$v"; echo "备份 v$v → $K";; *) echo "docker-compose 不是 v1（$v），不处理"; exit 0;; esac
  else f=/usr/local/bin/docker-compose; fi
  docker compose version >/dev/null 2>&1 || dnf -y install docker-compose-plugin >/dev/null 2>&1
  printf '#!/bin/sh\n# docker-compose v1 与 Docker>=25 不兼容（KeyError: ContainerConfig），转发到 Compose v2 插件\nexec docker compose "$@"\n' > "$f"; chmod 755 "$f"
  docker-compose version ;;

kubectl)
  want=$2
  if [ -z "$want" ] || [ "$want" = auto ]; then
    want=$(timeout 20 kubectl version -o json 2>/dev/null | grep -A3 '"serverVersion"' | grep -oE '"minor": *"[0-9]+' | grep -oE '[0-9]+$')
    [ -n "$want" ] && want=1.$want || { echo "取不到集群版本，请指定如: finalize.sh kubectl 1.30"; exit 1; }
  fi
  if [ "$MIR" = upstream ]; then base=https://pkgs.k8s.io/core:/stable:/v$want/rpm; else base=$MIR/kubernetes-new/core/stable/v$want/rpm; fi
  curl -sfI -m 15 "$base/repodata/repomd.xml" >/dev/null || base=https://pkgs.k8s.io/core:/stable:/v$want/rpm
  printf "[kubernetes]\nname=Kubernetes v%s\nbaseurl=%s/\nenabled=1\ngpgcheck=1\ngpgkey=%s/repodata/repomd.xml.key\n" "$want" "$base" "$base" > /etc/yum.repos.d/kubernetes.repo
  cp -a "$(command -v kubectl)" "$K/kubectl.old" 2>/dev/null
  rpm -q kubectl >/dev/null 2>&1 && ! rpm -q --qf '%{VERSION}' kubectl | grep -q "^$want\." && rpm -e kubectl
  [ -f /usr/local/bin/kubectl ] && mv /usr/local/bin/kubectl "$K/kubectl.usr-local"
  dnf -y install kubectl 2>&1 | tail -1; hash -r
  kubectl version --client 2>&1 | head -1; timeout 20 kubectl get nodes 2>&1 | head -5
  rpm -q bash-completion >/dev/null || dnf -y install bash-completion >/dev/null 2>&1 ;;

helm)
  v=$(curl -s -m 20 "https://api.github.com/repos/helm/helm/releases?per_page=30" | grep -oE '"tag_name": "v3\.[0-9]+\.[0-9]+"' | head -1 | grep -oE 'v3[0-9.]+')
  [ -z "$v" ] && { echo "取不到 helm 最新版本"; exit 1; }
  d=$(mktemp -d); cd "$d" || exit 1
  curl -fsSL -m 300 -o h.tgz "https://get.helm.sh/helm-$v-linux-amd64.tar.gz" && curl -fsSL -m 60 -o h.sha "https://get.helm.sh/helm-$v-linux-amd64.tar.gz.sha256sum"
  echo "$(cut -d' ' -f1 h.sha)  h.tgz" | sha256sum -c - || exit 1
  tar xzf h.tgz; old=$(command -v helm); [ -n "$old" ] && cp -a "$old" "$K/helm.old"
  install -m 755 linux-amd64/helm "${old:-/usr/local/bin/helm}"; cd / && rm -rf "$d"
  helm version --short ;;

postfix-lmdb)
  postconf -n | grep -E "(hash|btree):" | sed 's/^/转换前: /'
  for k in $(postconf -n | awk -F' = ' '$2 ~ /(hash|btree):/{print $1}'); do
    v=$(postconf -h "$k" | sed -E 's/(hash|btree):/lmdb:/g'); postconf -e "$k = $v"
  done
  postconf -e "default_database_type = lmdb" 2>/dev/null
  newaliases; for f in $(postconf -n | grep -oE "lmdb:[^ ,]+" | sed 's/lmdb://' | sort -u); do [ "$f" != /etc/aliases ] && [ -f "$f" ] && postmap "lmdb:$f"; done
  # 禁用了 IPv6 时 inet_protocols=all 会让 postfix 报 "no local interface found for ::1"（真实踩坑）
  ip -6 addr show lo 2>/dev/null | grep -q "::1" || { [ "$(postconf -h inet_protocols)" = all ] && postconf -e inet_protocols=ipv4 && echo "IPv6 已禁用 → inet_protocols=ipv4"; }
  systemctl restart postfix; systemctl is-active postfix
  echo test | sendmail root && sleep 2 && journalctl -u postfix --since -1min --no-pager -o cat | grep -E "status=" | tail -1 ;;

nginx-repo)
  cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/rhel/$releasever_major/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
  dnf -q makecache --repo nginx-stable 2>/dev/null || sed -i 's#\$releasever_major#10#' /etc/yum.repos.d/nginx.repo
  cp -a /etc/nginx "$K/etc-nginx.before-pkg" 2>/dev/null
  dnf -y install nginx --repo nginx-stable 2>&1 | grep -E "nginx|Complete|Error" | head -3
  /usr/sbin/nginx -v
  echo "已安装（未启动）。按 references/app-compat.md 的 nginx 迁移步骤写 /etc/nginx/conf.d 后再切换" ;;

cgroupv1-shim)
  d=${2:?需要 compose 目录}; cd "$d" || exit 1
  f=$(ls docker-compose.y*ml compose.y*ml 2>/dev/null | head -1); [ -n "$f" ] || { echo "没有 compose 文件"; exit 1; }
  cp -a "$f" "$f.bak-before-cgroupv2"
  mkdir -p cgroupv1-shim/memory; echo 9223372036854771712 > cgroupv1-shim/memory/memory.limit_in_bytes; echo 0 > cgroupv1-shim/memory/memory.usage_in_bytes
  echo "在 $f 的目标 service 下加入（若已有 volumes 就追加一行）:"
  echo "    volumes:"; echo "      - ./cgroupv1-shim:/sys/fs/cgroup:ro"
  echo "然后: docker compose up -d   （不要用 docker-compose v1）" ;;

sysv-units)
  for s in $(ls /etc/rc.d/init.d/ 2>/dev/null | grep -vE "^(functions|README|netconsole|network)$"); do
    [ -f /etc/systemd/system/$s.service ] && continue
    systemctl is-enabled "$s" 2>/dev/null | grep -q enabled || { echo "跳过未启用的 $s"; continue; }
    cat > /etc/systemd/system/$s.service <<EOF
[Unit]
Description=$s (wrapped SysV script /etc/rc.d/init.d/$s)
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
RemainAfterExit=yes
TimeoutStartSec=300
ExecStart=/etc/rc.d/init.d/$s start
ExecStop=/etc/rc.d/init.d/$s stop
[Install]
WantedBy=multi-user.target
EOF
    echo "生成 /etc/systemd/system/$s.service"
  done
  systemctl daemon-reload; echo "检查后执行 systemctl enable <name>；当前正在运行的不要 restart，下次开机生效" ;;

iptables-legacy) # 容器里用 iptables-legacy 的镜像（如 wg-easy）：EL10 默认不加载 legacy 表 → "can't initialize iptables table nat"（真实踩坑）
  printf 'ip_tables\niptable_nat\niptable_filter\niptable_mangle\nip6_tables\nip6table_nat\nip6table_filter\n' > /etc/modules-load.d/iptables-legacy-for-containers.conf
  while read -r m; do modprobe "$m" 2>/dev/null; done < /etc/modules-load.d/iptables-legacy-for-containers.conf
  echo "已加载并持久化 legacy iptables 模块：$(lsmod | grep -cE '^(ip|ip6)table_') 个表模块；重启相关容器（docker restart <name>）" ;;

redis-valkey) # EL10 没有 redis 包，leapp 换成 valkey 但不迁移数据/不启用（真实踩坑：redis.service 消失）
  rpm -q valkey >/dev/null 2>&1 || dnf -y install valkey 2>&1 | tail -1
  old=$(ls /etc/redis/redis.conf.rpmsave /etc/redis.conf.rpmsave /etc/redis/redis.conf /etc/redis.conf 2>/dev/null | head -1)
  [ -n "$old" ] && { echo "旧配置 $old 的关键项（核对后按需写进 /etc/valkey/valkey.conf）:"; grep -E "^(bind|port|requirepass|maxmemory|appendonly|save|dir|dbfilename) " "$old" | sed -E 's/^(requirepass ).*/\1***/'; }
  for f in /var/lib/redis/dump.rdb /var/lib/redis/appendonly.aof; do [ -f "$f" ] && [ ! -f "/var/lib/valkey/$(basename $f)" ] && install -o valkey -g valkey -m 640 "$f" /var/lib/valkey/ && echo "数据 $f → /var/lib/valkey/"; done
  grep -qE "^requirepass " "$old" 2>/dev/null && echo "!! 旧配置有 requirepass：请把同样的密码写进 /etc/valkey/valkey.conf 再启动"
  for b in cli server benchmark; do [ -e /usr/local/bin/redis-$b ] || ln -s /usr/bin/valkey-$b /usr/local/bin/redis-$b; done
  systemctl enable --now valkey 2>&1 | tail -1; sleep 2; redis-cli ping 2>&1 | head -1 ;;

manual-procs) # 升级前手工从 SSH 会话启动（nohup ... &）的进程，重启后不会自己起来：按 backup.sh 记录的 cmdline/cwd/环境变量生成 systemd 服务
  D=${2:?用法: finalize.sh manual-procs <BACKUP_DIR>/manual-procs}
  for c in "$D"/*.cmdline; do
    [ -e "$c" ] || continue
    p=${c%.cmdline}; cwd=$(cat "$p.cwd"); exe=$(cat "$p.exe" 2>/dev/null)
    name=osup-$(echo "$cwd" | sed -E 's#^/(data|opt|home|root)/##; s#/bin$##; s#/.*/#-#; s#[^A-Za-z0-9_.]+#-#g')
    [ -e "/etc/systemd/system/$name.service" ] && { echo "已存在 $name，跳过"; continue; }
    first=$(head -1 "$c"); case "$first" in /*) ;; *) [ -n "$exe" ] && first=$exe;; esac
    args=$(tail -n +2 "$c" | sed 's/%/%%/g' | awk '{gsub(/"/,"\\\""); printf " \"%s\"", $0}')
    envs=$(grep -E '^(PATH|JAVA_HOME|LANG|LC_ALL|CLASSPATH)=' "$p.environ" 2>/dev/null | sed 's/^/Environment="/; s/$/"/')
    printf '[Unit]\nDescription=Restored manual process in %s (was started by hand before the OS upgrade)\nAfter=network-online.target docker.service\nWants=network-online.target\n\n[Service]\nType=simple\nWorkingDirectory=%s\n%s\nExecStart=%s%s\nSuccessExitStatus=143\nTimeoutStopSec=60\n\n[Install]\nWantedBy=multi-user.target\n' \
      "$cwd" "$cwd" "$envs" "$first" "$args" > "/etc/systemd/system/$name.service"
    echo "生成 $name: $first $(tail -n +2 "$c" | tr '\n' ' ' | cut -c1-80)"
  done
  systemctl daemon-reload
  echo "检查 /etc/systemd/system/osup-*.service 后：systemctl enable --now <name>（LANG=zh_CN.GB18030 等需要 glibc-langpack-zh）" ;;

*) sed -n '2,15p' "$0";;
esac
