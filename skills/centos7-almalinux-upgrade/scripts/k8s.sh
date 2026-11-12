#!/bin/bash
# k8s.sh - Kubernetes 节点（kubeadm；docker/dockershim 或 containerd）原地升级的配套操作。K8s 版本保持不变
#
#   bash k8s.sh pin                # 在 k8s 源里 exclude kubelet/kubeadm/kubectl/cni/cri-tools，防止 dnf upgrade 升 minor（backup 会自动做）
#   bash k8s.sh backup             # 备份 /etc/kubernetes、kubelet/CNI/运行时配置、K8s 二进制；master 上做 etcd 快照；
#                                  # 能连 apiserver 时导出节点/pod 列表和常用资源 YAML（升级前每台都做）
#   bash k8s.sh stop               # 重启前：停 kubelet，再按"业务 → 控制面 → etcd"的顺序优雅停止 k8s_ 容器
#   bash k8s.sh nfs-off / nfs-on   # 升级期间临时注释 fstab 的 NFS 并卸载所有 NFS（leapp 阻断项），EL10 后恢复
#   bash k8s.sh nm                 # 让 NetworkManager 不接管 cni0/flannel/veth/docker/kube-ipvs0 等容器网卡（切 NM 后立刻做；fix 也会做）
#   bash k8s.sh fix                # 每跳之后（EL8+）：模块自动加载、sysctl、kubelet 二进制/rpm 还在、cgroup 驱动一致、kubelet 开机自启
#   bash k8s.sh check              # 节点自检：kubelet、运行时、cgroup、本机 k8s 容器、kubelet 最近报错
#   bash k8s.sh jvm-maxram ns1,ns2 [--dry-run]  # cgroup v2 下老 JDK 认不出容器内存限制 → 注入 JAVA_TOOL_OPTIONS=-XX:MaxRAM=$(limits.memory)
#   bash k8s.sh pods [before.txt]  # 集群级（需要 kubectl 能用）：节点、非 Running 的 pod、与升级前按 namespace 的 Running 数对比
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
K=/root/os-upgrade-kit; mkdir -p "$K"
EL=$(rpm -E %rhel 2>/dev/null)
kc() { timeout 30 kubectl "$@" 2>/dev/null; }
kube_ok() { command -v kubectl >/dev/null 2>&1 && kc get --raw /healthz >/dev/null; }

pin() { # K8s 组件版本钉死：hop.sh post / dnf upgrade 不能把 kubelet/kubeadm 升到新 minor（会把节点或集群搞坏）
  # 只改 k8s 源文件，不动 dnf.conf/yum.conf 的 [main]（leapp 会迁移主配置；以后要重装同版本用 --disableexcludes=all）
  for f in /etc/yum.repos.d/*.repo; do
    [ -e "$f" ] || continue
    grep -qiE "kubernetes|pkgs\.k8s\.io" "$f" || continue
    grep -qE "^exclude=.*kubelet" "$f" || { sed -i -E '/^\[.*\]/a exclude=kubelet kubeadm kubectl kubernetes-cni cri-tools' "$f"; echo "已钉住 K8s 组件版本: $f"; }
  done
}

nm_unmanaged() { # NM 默认会接管新出现的网卡（给 veth/cni0 建 "Wired connection"、改地址），会搅乱 pod 网络
  [ -d /etc/NetworkManager ] || return 0
  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/99-k8s-unmanaged.conf <<'NMEOF'
[keyfile]
unmanaged-devices=interface-name:cni0;interface-name:flannel*;interface-name:veth*;interface-name:docker*;interface-name:br-*;interface-name:kube-ipvs0;interface-name:kube-bridge;interface-name:cali*;interface-name:tunl*;interface-name:vxlan*;interface-name:cilium*;interface-name:lxc*;interface-name:wt*;interface-name:nodelocaldns
NMEOF
  systemctl is-active NetworkManager >/dev/null 2>&1 && nmcli general reload conf 2>/dev/null
  echo "NM 不接管容器网卡: /etc/NetworkManager/conf.d/99-k8s-unmanaged.conf"
}

case "$1" in
nfs-off) # leapp 阻断项 "Use of NFS detected"：pod 的 NFS PVC 挂载 + fstab 里的 NFS。先 drain（或 stop）再执行
  systemctl is-active kubelet >/dev/null 2>&1 && echo "WARN: kubelet 还在运行，它会重新挂载 pod 的 NFS 卷 → 先 kubectl drain 本节点或 k8s.sh stop"
  grep -nE "^[^#].*[[:space:]](nfs|nfs4)[[:space:]]" /etc/fstab && { cp -n /etc/fstab $K/fstab.before-nfs-off; sed -i -E 's/^([^#].*[[:space:]](nfs|nfs4)[[:space:]].*)$/#osup-nfs# \1/' /etc/fstab; echo "fstab 里的 NFS 已临时注释（标记 #osup-nfs#），EL10 后用 k8s.sh nfs-on 恢复"; }
  awk '$3=="nfs"||$3=="nfs4" {print $2}' /proc/mounts | sort -r | while read -r m; do umount "$m" 2>/dev/null || umount -l "$m"; echo "umount $m"; done
  n=$(awk '$3=="nfs"||$3=="nfs4"' /proc/mounts | wc -l); echo "剩余 NFS 挂载: $n"
  ;;
nfs-on)
  grep -q "^#osup-nfs# " /etc/fstab && { sed -i -E 's/^#osup-nfs# //' /etc/fstab; echo "fstab NFS 已恢复"; }
  rpm -q nfs-utils >/dev/null 2>&1 || dnf -y install nfs-utils 2>&1 | tail -1
  mount -a -t nfs,nfs4 2>&1; awk '($3=="nfs"||$3=="nfs4") {print "已挂载 "$1" → "$2}' /proc/mounts | grep -v kubelet
  # hop.sh reboot 在 NFS 下线时 mask 了 docker（非 K8s 主机）：fstab 里的 NFS 全部挂上才放开并启动
  if [ -f "$K/docker-masked-for-nfs" ]; then
    miss=$(awk '$1 !~ /^#/ && ($3=="nfs"||$3=="nfs4") {print $2}' /etc/fstab | while read -r m; do mountpoint -q "$m" || echo "$m"; done)
    if [ -n "$miss" ]; then echo "!! 这些 NFS 还没挂上，docker 保持 mask：$miss"
    else systemctl unmask docker.service docker.socket >/dev/null 2>&1; systemctl enable --now docker.socket docker.service >/dev/null 2>&1
      rm -f "$K/docker-masked-for-nfs"; echo "NFS 已全部挂上：docker 已 unmask 并启动（$(systemctl is-active docker)）"; fi
  fi
  ;;
nm) nm_unmanaged; nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep -vE ":unmanaged$" ;;
pin) pin; grep -H "^exclude=" /etc/yum.repos.d/*.repo 2>/dev/null ;;
backup)
  pin
  D=$K/k8s-backup-$(date +%Y%m%d-%H%M); mkdir -p "$D"
  L=""; for p in /etc/kubernetes /var/lib/kubelet/config.yaml /var/lib/kubelet/kubeadm-flags.env /etc/sysconfig/kubelet \
      /etc/cni/net.d /usr/lib/systemd/system/kubelet.service /usr/lib/systemd/system/kubelet.service.d /etc/systemd/system/kubelet.service.d \
      /etc/docker/daemon.json /etc/containerd/config.toml /etc/crictl.yaml /etc/sysconfig/modules /etc/modules-load.d /etc/sysctl.d /etc/sysctl.conf \
      /root/.kube /root/kubeadm; do [ -e "$p" ] && L="$L $p"; done
  # shellcheck disable=SC2086
  tar czf "$D/config.tgz" $L 2>/dev/null && echo "配置 → $D/config.tgz"
  B=""; for p in /usr/bin/kubelet /usr/bin/kubeadm /usr/bin/kubectl /usr/bin/crictl /opt/cni/bin; do [ -e "$p" ] && B="$B $p"; done
  # shellcheck disable=SC2086
  [ -n "$B" ] && tar czf "$D/bin.tgz" $B 2>/dev/null && echo "二进制 → $D/bin.tgz（升级后 rpm 被删时可还原）"
  rpm -qa 2>/dev/null | grep -E "^(kube|cri-tools|docker|containerd|runc)" | sort > "$D/rpms.txt"
  if [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
    c=$(docker ps -q --filter name=k8s_etcd_ 2>/dev/null | head -1)
    if [ -n "$c" ]; then
      P=/etc/kubernetes/pki/etcd
      docker exec -e ETCDCTL_API=3 "$c" etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$P/ca.crt --cert=$P/server.crt --key=$P/server.key \
        snapshot save /var/lib/etcd/osup-snapshot.db >/dev/null 2>&1 && mv /var/lib/etcd/osup-snapshot.db "$D/etcd-snapshot.db" \
        && echo "etcd 快照 → $D/etcd-snapshot.db ($(du -h "$D/etcd-snapshot.db" | cut -f1))" || echo "!! etcd 快照失败（手动: docker exec <etcd> etcdctl snapshot save）"
      docker exec -e ETCDCTL_API=3 "$c" etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$P/ca.crt --cert=$P/server.crt --key=$P/server.key \
        member list -w table > "$D/etcd-members.txt" 2>&1
    else echo "!! 本机是 stacked etcd 但没找到 etcd 容器（containerd 运行时请用 crictl exec）"; fi
  fi
  if kube_ok; then
    kc get nodes -o wide > "$D/nodes.txt"; kc get pods -A -o wide > "$D/pods-before.txt"
    kc get deploy,sts,ds,cronjob -A > "$D/workloads-before.txt"
    kc get deploy,sts,ds,svc,ing,cm,secret,pvc,cronjob -A -o yaml > "$D/resources.yaml"; kc get pv,sc,crd -o yaml > "$D/cluster-resources.yaml"
    # 只保留第一次（真正升级前）的 pod 列表：中途再 backup 不能覆盖（drain 之后的状态没有对比价值，真实踩坑）
    cp -n "$D/pods-before.txt" "$K/k8s-pods-before.txt"
    echo "集群: $(grep -c . "$D/nodes.txt") 行节点, $(tail -n +2 "$D/pods-before.txt" | wc -l) 个 pod（列表 → $K/k8s-pods-before.txt）"
  fi
  ls -la "$D"
  ;;

stop)
  systemctl stop kubelet && echo "kubelet 已停止（重启后由 enabled 状态自动拉起）"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    all=$(docker ps --filter name=k8s_ --format '{{.ID}} {{.Names}}')
    biz=$(echo "$all" | grep -vE " k8s_(etcd|kube-apiserver|kube-controller-manager|kube-scheduler)_" | awk 'NF{print $1}')
    cp=$(echo "$all" | grep -E " k8s_(kube-apiserver|kube-controller-manager|kube-scheduler)_" | awk '{print $1}')
    et=$(echo "$all" | grep -E " k8s_etcd_" | awk '{print $1}')
    # shellcheck disable=SC2086
    [ -n "$biz" ] && { echo "停止 $(echo "$biz" | wc -l) 个业务/系统 pod 容器"; docker stop -t 30 $biz >/dev/null; }
    # shellcheck disable=SC2086
    [ -n "$cp" ] && { echo "停止控制面容器"; docker stop -t 30 $cp >/dev/null; }
    # shellcheck disable=SC2086
    [ -n "$et" ] && { echo "停止 etcd"; docker stop -t 60 $et >/dev/null; }
  elif command -v crictl >/dev/null 2>&1; then
    crictl ps -q | xargs -r crictl stop >/dev/null 2>&1 && echo "已停止 CRI 容器"
  fi
  ;;

fix)
  nm_unmanaged
  [ "${EL:-7}" -ge 8 ] || { echo "EL7 上不需要（只在升级后的 EL8+ 上运行）"; exit 0; }
  # EL7 的 /etc/sysconfig/modules/*.modules 由 initscripts 加载，EL8+ 没人执行 → 改用 modules-load.d（nf_conntrack_ipv4 在 4.19+ 内核已并入 nf_conntrack）
  : > /etc/modules-load.d/k8s.conf
  for m in br_netfilter overlay nf_conntrack ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh ip_vs_lc ip_vs_wlc; do
    modinfo -n "$m" >/dev/null 2>&1 && { echo "$m" >> /etc/modules-load.d/k8s.conf; modprobe "$m" 2>/dev/null; }
  done
  echo "模块自动加载: $(tr '\n' ' ' < /etc/modules-load.d/k8s.conf)"
  printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-k8s-osup.conf
  sysctl -p /etc/sysctl.d/99-k8s-osup.conf >/dev/null && echo "sysctl: bridge-nf-call-iptables=$(sysctl -n net.bridge.bridge-nf-call-iptables) ip_forward=$(sysctl -n net.ipv4.ip_forward)"
  # Dead 状态的 k8s_ 容器（升级重启中途被杀）会让 kubelet 起不来：
  #   "Failed to start ContainerManager ... no PodsandBox found with Id ..."（真实踩坑，exited 过滤器抓不到 dead）
  if command -v docker >/dev/null 2>&1; then
    d=$(docker ps -a --filter status=dead -q 2>/dev/null); [ -n "$d" ] && { echo "删除 Dead 状态的容器: $(echo $d | wc -w) 个"; echo "$d" | xargs -r docker rm -f >/dev/null 2>&1; }
  fi
  swapon --show 2>/dev/null | grep -q . && echo "!! swap 已开启（kubelet 默认要求关闭）：swapoff -a 并注释 fstab"
  for b in kubelet kubeadm kubectl; do
    [ -x /usr/bin/$b ] && continue
    bk=$(ls -t $K/k8s-backup-*/bin.tgz 2>/dev/null | head -1)
    if [ -n "$bk" ]; then tar xzf "$bk" -C / usr/bin/$b 2>/dev/null && echo "!! /usr/bin/$b 不见了 → 已从 $bk 还原（rpm 记录可能已丢，见 rpms.txt）"
    else echo "!! /usr/bin/$b 不见了，且没有 k8s.sh backup 的备份"; fi
  done
  rpm -q kubelet >/dev/null 2>&1 || echo "WARN: kubelet 不再是 rpm 管理（二进制在就能跑；以后从 pkgs.k8s.io 同版本重装）"
  kd=$(awk '/^cgroupDriver:/{print $2}' /var/lib/kubelet/config.yaml 2>/dev/null)
  rd=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null)
  [ -n "$kd" ] && [ -n "$rd" ] && { [ "$kd" = "$rd" ] && echo "cgroup 驱动一致: $kd" || echo "!! cgroup 驱动不一致: kubelet=$kd 运行时=$rd（改 /etc/docker/daemon.json exec-opts 或 kubelet config）"; }
  echo "cgroup: $(stat -fc %T /sys/fs/cgroup)（cgroup2fs = v2）"
  systemctl daemon-reload; systemctl enable kubelet >/dev/null 2>&1; echo "kubelet: enabled=$(systemctl is-enabled kubelet) active=$(systemctl is-active kubelet)"
  ;;

check)
  echo "== $(hostname) $(cat /etc/redhat-release) kernel $(uname -r) cgroup=$(stat -fc %T /sys/fs/cgroup)"
  echo "kubelet: $(systemctl is-active kubelet) $(/usr/bin/kubelet --version 2>/dev/null)"
  command -v docker >/dev/null && echo "docker: $(docker version --format '{{.Server.Version}} (API min {{.Server.MinAPIVersion}})' 2>/dev/null) driver=$(docker info --format '{{.CgroupDriver}} storage={{.Driver}}' 2>/dev/null)"
  if command -v docker >/dev/null 2>&1; then
    t=$(docker ps -a --filter name=k8s_ -q | wc -l); r=$(docker ps --filter name=k8s_ -q | wc -l)
    echo "k8s 容器: running $r / 全部 $t"
    docker ps --filter name=k8s_ --format '{{.Names}} {{.Status}}' | grep -vE "k8s_POD_" | awk '{print $1}' | sed -E 's/^k8s_([^_]+)_([^_]+)_([^_]+)_.*/\3\/\2 (\1)/' | sort | head -80 | tr '\n' ' '; echo
  fi
  # flannel.1 上有 IPv6 地址：IPv6 组播在 VXLAN FDB 里没有条目 → tx_dropped 每小时涨一点 → 监控"出方向丢包"告警（真实踩坑：只有一台节点没禁 IPv6）
  ip -6 addr show dev flannel.1 2>/dev/null | grep -q inet6 && echo "WARN flannel.1 有 IPv6 地址（tx_dropped=$(cat /sys/class/net/flannel.1/statistics/tx_dropped 2>/dev/null)）：和其它节点一样禁用 IPv6（sysctl net.ipv6.conf.all/default.disable_ipv6=1），见 kubernetes.md"
  echo "-- kubelet 最近 5 分钟的错误（去重）:"
  journalctl -u kubelet --since "-5min" --no-pager 2>/dev/null | grep -E " E[0-9]{4} " | sed -E 's/.*\] //' | cut -c1-200 | sort | uniq -c | sort -rn | head -8
  ;;

pods)
  kube_ok || { echo "kubectl 连不上 apiserver"; exit 1; }
  BEF=${2:-$K/k8s-pods-before.txt}
  echo "== 节点"; kc get nodes -o wide | awk '{print $1, $2, $5, $8, $(NF-1), $NF}' | column -t
  echo "== 不是 Running/Completed 的 pod"; kc get pods -A -o wide --no-headers | awk '$4!="Running" && $4!="Completed"{print $1, $2, $4, $8}' | column -t
  echo "== Running 但容器未全部 Ready"; kc get pods -A --no-headers | awk '$4=="Running"{split($3,a,"/"); if(a[1]!=a[2]) print $1, $2, $3}' | column -t
  if [ -f "$BEF" ]; then
    echo "== 各 namespace Running pod 数：升级前 → 现在"
    join -a1 -a2 -e0 -o 0,1.2,2.2 <(awk 'NR>1 && $4=="Running"{c[$1]++} END{for(n in c) print n, c[n]}' "$BEF" | sort) \
      <(kc get pods -A --no-headers | awk '$4=="Running"{c[$1]++} END{for(n in c) print n, c[n]}' | sort) \
      | awk '{m=($2==$3)?"":"   <<<"; print $1, $2, "->", $3 m}' | column -t   # LC_ALL=C 下 column 会把 "→" 转义成 \xe2...
  fi
  ;;

jvm-maxram) # cgroup v2 下老 JDK（8u372 / 11.0.16 之前）认不出容器内存限制，按宿主机内存算堆 → OOMKilled（真实踩坑）
  # 给指定 namespace 里有 limits.memory 的容器注入 JAVA_TOOL_OPTIONS=-XX:MaxRAM=$(limits.memory)（downward API），
  # 恢复 cgroup v1 时的堆大小；镜像和启动命令不变。会触发滚动更新。用法: k8s.sh jvm-maxram ns1,ns2 [--dry-run]
  kube_ok || { echo "kubectl 连不上 apiserver"; exit 1; }
  NS=${2:?用法: k8s.sh jvm-maxram ns1,ns2 [--dry-run]}
  PY=$(command -v python3 || command -v python || echo /usr/libexec/platform-python)
  kc get deploy,sts -A -o yaml > "$K/workloads-before-jvm-maxram-$(date +%Y%m%d-%H%M).yaml"
  kc get deploy,sts -A -o json | PYTHONIOENCODING=utf-8 "$PY" -c '
# -*- coding: utf-8 -*-
from __future__ import print_function, unicode_literals
import json, subprocess, sys
ns_list = sys.argv[1].split(","); dry = len(sys.argv) > 2 and sys.argv[2] == "--dry-run"
n = 0
for it in json.load(sys.stdin)["items"]:
    ns, name, kind = it["metadata"]["namespace"], it["metadata"]["name"], it["kind"].lower()
    if ns not in ns_list: continue
    ctrs = []
    for c in it["spec"]["template"]["spec"]["containers"]:
        if not (c.get("resources") or {}).get("limits", {}).get("memory"): continue
        env = dict((e["name"], e) for e in c.get("env", []))
        if "OSUP_MEM_LIMIT" in env: continue
        jto = env.get("JAVA_TOOL_OPTIONS", {}).get("value", "")
        ctrs.append({"name": c["name"], "env": [
            {"name": "OSUP_MEM_LIMIT", "valueFrom": {"resourceFieldRef": {"containerName": c["name"], "resource": "limits.memory"}}},
            {"name": "JAVA_TOOL_OPTIONS", "value": ("-XX:MaxRAM=$(OSUP_MEM_LIMIT) " + jto).strip()}]})
    if not ctrs: continue
    n += 1
    if dry: print("would patch %s %s/%s" % (kind, ns, name)); continue
    subprocess.call(["kubectl", "-n", ns, "patch", kind, name, "--type=strategic", "-p",
                     json.dumps({"spec": {"template": {"spec": {"containers": ctrs}}}})])
print("workloads: %d" % n)
' "$NS" "$3"
  echo "提示：滚动更新期间新旧 pod 同时启动会抢 CPU；旧 ReplicaSet 的 pod 反正会 OOM，可 kubectl scale rs <旧RS> --replicas=0"
  ;;

*) sed -n '2,13p' "$0";;
esac
