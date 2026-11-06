#!/bin/bash
# finalize.sh - 到达 EL10 后的收尾/现代化工具（按需选用，每个子命令独立）
#
#   bash finalize.sh compose-wrapper          docker-compose v1 → 转发到 "docker compose" 的包装脚本（原文件备份）
#   bash finalize.sh kubectl [auto|1.30]      kubectl 换成 pkgs.k8s.io 源、与集群同 minor 版本（auto=按 kubeconfig 集群版本）
#   bash finalize.sh helm                     helm 升级到最新 v3（sha256 校验）
#   bash finalize.sh postfix-lmdb             postfix 的 hash:/btree: 表改 lmdb:（EL10 无 libdb）并重建
#   bash finalize.sh nginx-repo               添加 nginx.org 官方 stable 源并安装 nginx（不改配置、不启动）
#   bash finalize.sh cgroupv1-shim <compose目录>  给需要 cgroup v1 内存文件的老应用挂只读兼容文件并重建容器
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

*) sed -n '2,12p' "$0";;
esac
