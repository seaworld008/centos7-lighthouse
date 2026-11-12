#!/bin/bash
# hop.sh - 用 AlmaLinux ELevate 做一跳大版本升级（7→8 / 8→9 / 9→10），每个子命令都可重复执行
#
#   bash hop.sh prep   <MIRROR>    清理上一跳残留 → 安装本跳 ELevate → 目标源/厂商源改镜像 → pip 冲突清理 → 探测源可达
#   bash hop.sh pre                后台跑 leapp preupgrade 并等待，结束后自动 report
#   bash hop.sh report             汇总：阻断项(含修复命令) / 高中风险 / 未答问题 / 事务里会被删除的包
#   bash hop.sh answer             自动回答已知安全的问题（pam_pkcs11、确认无 VDO 后的 check_vdo）
#   bash hop.sh up                 后台跑 leapp upgrade（下载+生成升级环境）并等待
#   bash hop.sh reboot [容器...]    安全重启：只优雅停止有状态且 restart=always 的容器（及参数指定的），绝不 stop 全部
#   bash hop.sh reboot --no-stop    不提前停止任何容器（业务方要求某些容器"不能动"时），交给 docker.service 关机时优雅停止
#   bash hop.sh post   <MIRROR>    重启进入新版本后：检查成功标记 → 删 leapp/旧内核/残留 → 修 repo → dnf upgrade
#   bash hop.sh status             看当前 leapp 进度
# MIRROR 同 prep-el7.sh（https://mirrors.aliyun.com / http://mirrors.cloud.aliyuncs.com / https://repo.huaweicloud.com / upstream）
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
K=/root/os-upgrade-kit; mkdir -p "$K"
CUR=$(rpm -E %rhel); TGT=$((CUR+1))
PY=$(command -v python3 || command -v python)
[ -x /usr/libexec/platform-python ] && PY=/usr/libexec/platform-python
PKG=yum; command -v dnf >/dev/null && PKG=dnf
LL=${LEAPP_LOG_DIR:-/var/log/leapp}   # leapp 日志/报告目录；测试时指向临时目录

bgwait() { # bgwait <logfile>：等待 __RC= 行
  local log=$1 t=0
  until grep -q "^__RC=" "$log" 2>/dev/null; do
    sleep 15; t=$((t+15)); [ $((t % 180)) = 0 ] && echo "  ...${t}s $(grep -v '^\s*$' "$log" 2>/dev/null | tail -1 | cut -c1-110)"
  done
  local rc; rc=$(sed -n 's/^__RC=//p' "$log" | tail -1); echo "__RC=${rc:-?}"; return "${rc:-1}"   # 把后台命令的退出码传出去
}
bgrun() { # bgrun <name> <cmd>
  local log=$K/$1.log; rm -f "$log"
  systemd-run --unit="osup-$1-$(date +%s)" /bin/bash -c "$2 > $log 2>&1; echo __RC=\$? >> $log" >/dev/null
  echo "后台任务 $1 已启动（systemd-run，SSH 断开不影响），日志 $log"; bgwait "$log"
}

rewrite_mirrors() { # rewrite_mirrors <MIRROR> <files...>
  local M=$1; shift; [ "$M" = upstream ] && return 0
  for f in "$@"; do [ -f "$f" ] || continue; mkdir -p "$K/repo-orig"; cp -n "$f" "$K/repo-orig/$(basename "$f").orig" 2>/dev/null   # 备份放到工具目录，不污染 yum.repos.d
    sed -i -E \
      -e 's#^(mirrorlist=https?://mirrors\.almalinux\.org.*)#\#\1#' \
      -e "s#^\#? ?baseurl=https?://repo\.almalinux\.org/almalinux/#baseurl=$M/almalinux/#" \
      -e 's#^(metalink=https?://mirrors\.fedoraproject\.org.*)#\#\1#' \
      -e "s#^\#? ?baseurl=https?://(dl\.fedoraproject\.org|download\.example|download\.fedoraproject\.org)/pub/epel/#baseurl=$M/epel/#" \
      -e "s#https?://download\.docker\.com/#$M/docker-ce/#" "$f"
  done
}
disable_noise_sections() { # 关掉 test/nightly/debug/source 段（docker nightly 默认开着，国内常超时导致 leapp 失败）
  for f in "$@"; do [ -f "$f" ] || continue
    awk 'BEGIN{n=0} /^\[/{n=($0 ~ /(test|nightly|debug|source|testing)/)} { if(n && $0 ~ /^enabled *= *1/) print "enabled=0"; else print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}
clear_leapp_excludes() { sed -i -E '/^exclude=.*(leapp|snactor)/d' /etc/dnf/dnf.conf /etc/yum.conf 2>/dev/null; }
pipfix() {
  local D n=0; D=$K/python-unowned-el$CUR-$(date +%s)
  for d in /usr/lib/python2.7/site-packages /usr/lib64/python2.7/site-packages /usr/lib/python3.6/site-packages /usr/lib64/python3.6/site-packages /usr/lib/python3.9/site-packages /usr/lib64/python3.9/site-packages; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do [ -e "$f" ] || continue; rpm -qf "$f" >/dev/null 2>&1 || { mkdir -p "$D$d"; mv "$f" "$D$d/"; n=$((n+1)); }; done
  done
  echo "pip 冲突清理：挪走 $n 个不属于 rpm 的 site-packages 文件 ${n:+→ $D}"
}

# 优雅停止有状态容器（restart=always 的才停：开机/docker 重启后会自己拉起）。记录到 $K/stateful-stopped.txt
# docker 默认 10s 就 SIGKILL：GitLab omnibus（内置 PostgreSQL/Redis）来不及关 → 残留锁文件，下次起不来（真实踩坑）
STATEFUL_RE="mysql|mariadb|postgres|mongo|redis|elasticsearch|opensearch|clickhouse|kafka|zookeeper|etcd|minio|rabbitmq|influx|tdengine|nacos|gitlab|gitea|gogs|sonarqube|nexus|jira|confluence|harbor"
stop_stateful() { # stop_stateful [额外容器名...]
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || return 0
  : > $K/stateful-stopped.txt
  for c in $(docker ps -q); do
    n=$(docker inspect -f '{{.Name}}' $c | tr -d /); img=$(docker inspect -f '{{.Config.Image}}' $c); pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $c)
    want=0; echo "$img $n" | grep -qiE "$STATEFUL_RE" && want=1
    for x in "$@"; do [ "$x" = "$n" ] && want=1; done
    echo "$img $n" | grep -qiE "netbird|wireguard|wg-|openvpn|tailscale|zerotier|frp|ipsec|vpn" && { echo "跳过 VPN/隧道容器 $n（停了可能失联）"; continue; }
    [ $want = 1 ] || continue
    if [ "$pol" = always ]; then echo "优雅停止有状态容器 $n (restart=always，最长等 300s)"; docker stop -t 300 $c >/dev/null && echo "$n" >> $K/stateful-stopped.txt
    else echo "WARN: $n restart=$pol，docker stop 后不会自启 → 不手动停（建议 compose 里给它加 stop_grace_period）"; fi
  done
}
start_stateful() { # post 结束时把 stop_stateful 停掉、还没被 docker 重启拉起的容器启动回来
  [ -s $K/stateful-stopped.txt ] || return 0
  while read -r n; do [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = true ] || { echo "启动之前优雅停止的容器 $n"; docker start "$n" >/dev/null; }; done < $K/stateful-stopped.txt
  : > $K/stateful-stopped.txt
}
case "$1" in
prep)
  M=${2:?需要 MIRROR}
  [ "$CUR" -ge 10 ] && { echo "已经是 EL$CUR"; exit 0; }
  echo "== 当前 EL$CUR → 目标 EL$TGT"
  [ "$CUR" = 7 ] && ! grep -q "7\.9" /etc/redhat-release && { echo "!! 先 prep-el7.sh update 到 7.9"; exit 1; }
  clear_leapp_excludes
  stale=$(rpm -qa | grep -E "^(leapp|python[23]?-leapp|snactor|elevate-release|leapp-upgrade|leapp-data|leapp-deps|leapp-repository)" | grep -v "\.el$CUR")
  [ -n "$stale" ] && { echo "删除上一跳残留: $stale"; rpm -e --nodeps $stale; rm -rf /etc/leapp/files /etc/leapp/repos.d; }
  rm -f /etc/yum.repos.d/ELevate.repo
  if [ "$CUR" = 8 ] && rpm -qa 'python2*' | grep -q .; then  # EL9 没有 python2
    deps=$(for p in $(rpm -qa 'python2*' --qf '%{NAME}\n'); do dnf -q repoquery --installed --whatrequires "$p" --qf '%{name}' 2>/dev/null; done | sort -u | grep -vE "^(python2|leapp)")
    if [ -n "$deps" ]; then echo "!! 这些包依赖 python2，EL9 上会失效，先确认/处理后再移除 python2: $deps"
    else echo "EL8→9：移除 python2（无其它包依赖）"; $PKG -y remove 'python2*' 2>&1 | tail -1; $PKG -y module reset python27 >/dev/null 2>&1; fi
  fi
  $PKG -y install "https://repo.almalinux.org/elevate/elevate-release-latest-el$CUR.noarch.rpm" 2>&1 | tail -1
  $PKG -y install leapp-upgrade leapp-data-almalinux 2>&1 | tail -1
  rpm -qa | grep -E "leapp" | sort | tr '\n' ' '; echo
  [ -f /etc/leapp/files/leapp_upgrade_repositories.repo ] || { echo "!! leapp 数据文件不存在，安装失败？"; exit 1; }
  rewrite_mirrors "$M" /etc/leapp/files/leapp_upgrade_repositories.repo /etc/leapp/files/vendors.d/*.repo
  disable_noise_sections /etc/leapp/files/vendors.d/*.repo
  pipfix
  # EL9.6+/EL10 的 OpenSSH 9.9 有 PerSourcePenalties：重启后 wait-ssh 反复探测端口（连上不认证就断）算 noauth 惩罚，
  # 经 VPN/跳板 NAT 时所有操作同一个源 IP，会被拒 "Not allowed at this time" 好几分钟（真实踩坑）→ 把当前 SSH 来源 IP 豁免
  src=${SSH_CLIENT%% *}
  if [ "$TGT" -ge 9 ] && [ -n "$src" ] && [ -d /etc/ssh ]; then
    pf=/etc/ssh/sshd_config.d/05-osup-penalty-exempt.conf
    if [ ! -f "$pf" ]; then
      mkdir -p /etc/ssh/sshd_config.d; echo "PerSourcePenaltyExemptList $src" > "$pf"
      if sshd -t 2>/dev/null; then echo "sshd：$src 写入 PerSourcePenaltyExemptList（$pf；当前 sshd 若不读该目录/不认识该参数，升级后生效）"
      else rm -f "$pf"; echo "WARN: 当前 sshd 读取 sshd_config.d 但不认识 PerSourcePenaltyExemptList，未写入；到 EL9.6+ 后重跑 hop.sh prep"; fi
    fi
  fi
  # EL9 起 libcrypt.so.1 拆到 libxcrypt-compat（默认不装）：自编译 nginx/mysqld 等依赖它，升级后开机起不来（真实踩坑）
  # → 让 leapp 在升级事务里一起装上（/etc/leapp/transaction/to_install）
  if [ "$TGT" -ge 9 ]; then
    need=""
    for e in $(ls -l /proc/[0-9]*/exe 2>/dev/null | awk '{print $NF}' | grep '^/' | sort -u); do
      [ -f "$e" ] || continue; rpm -qf "$e" >/dev/null 2>&1 && continue
      ldd "$e" 2>/dev/null | grep -q 'libcrypt\.so\.1 ' && need="$need $e"
    done
    if [ -n "$need" ]; then
      mkdir -p /etc/leapp/transaction; grep -qx libxcrypt-compat /etc/leapp/transaction/to_install 2>/dev/null || echo libxcrypt-compat >> /etc/leapp/transaction/to_install
      echo "这些非 rpm 程序依赖 libcrypt.so.1，已把 libxcrypt-compat 加入 leapp 安装列表:$need"
    fi
  fi
  echo "== 探测目标源（\$releasever=$TGT）:"
  bad=0
  # 厂商源只探测本机在用的：leapp 按 <vendor>.sigs 里的签名 key 与已安装包的签名匹配来启用厂商源（PES 可能是空的，如 docker-ce）
  KEYS=$(rpm -qa --qf '%{SIGPGP:pgpsig}\n' 2>/dev/null | grep -oiE "key id [0-9a-f]+" | awk '{print tolower($3)}' | sort -u)
  vend=""
  for r in /etc/leapp/files/vendors.d/*.repo; do
    v=$(basename "$r" .repo); s=/etc/leapp/files/vendors.d/$v.sigs
    rpm -q --qf '%{VENDOR}' "$v" 2>/dev/null | grep -qvE "AlmaLinux|CloudLinux|Red Hat|CentOS|not installed" && { vend="$vend $r"; continue; }   # 同名第三方包已装（如 docker-ce；leapp 装的包可能没有签名）
    [ -f "$s" ] || continue
    for k in $(grep -oiE "[0-9a-f]{16}" "$s" | tr 'A-F' 'a-f'); do echo "$KEYS" | grep -q "${k: -8}$\|$k" && { vend="$vend $r"; break; }; done
  done
  echo "  使用中的厂商源:${vend:- 无}"
  for u in $(grep -hE "^baseurl=" /etc/leapp/files/leapp_upgrade_repositories.repo | head -3) $( [ -n "$vend" ] && awk '/^\[/{e=0} /^enabled *= *1/{e=1} /^baseurl=/{b=$0} e&&b{print b; b=""}' $vend | sort -u); do
    url=$(echo "${u#baseurl=}" | sed -e "s/\$releasever/$TGT/g" -e 's/\$basearch/x86_64/g' -e 's/\${stream:+s}//g' -e "s/\$releasever_major/$TGT/g")
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${url%/}/repodata/repomd.xml"); echo "  $code  $url"; [ "$code" = 200 ] || bad=$((bad+1))
  done
  [ $bad -gt 0 ] && echo "!! 有 $bad 个源不可达：对应厂商的包若已安装会导致 leapp 失败，换镜像或把该段 enabled=0"
  echo "完成。下一步: hop.sh pre"
  ;;

pre)
  bgrun leapp-pre-$TGT "leapp preupgrade"; bash "$0" report ;;

up)
  # leapp 在生成升级 initramfs 时把 fstab 的每一项做成 mount unit 固化进去；bind 到 /sys /proc /dev /run 的条目
  # （如阿里云 set_ecs_special.sh 写的 eth0-speed.mock → /sys/class/net/eth0/speed）在升级环境里挂不上 → 进 emergency
  # （真实踩坑，nofail 也没用；shell 在 ttyS0，VNC 里敲不了命令）。必须在 leapp upgrade 之前注释，事后再改 fstab 无效
  if grep -qE '^[^#]\S*\s+/(sys|proc|dev|run)/\S*\s+\S+\s+\S*bind' /etc/fstab; then
    cp -n /etc/fstab "$K/fstab.before-bind-off"
    grep -E '^[^#]\S*\s+/(sys|proc|dev|run)/\S*\s+\S+\s+\S*bind' /etc/fstab | sed 's/^/临时注释 fstab bind 挂载（EL10 的 post 自动恢复）: /'
    sed -i -E 's@^([^#]\S*\s+/(sys|proc|dev|run)/\S*\s+\S+\s+\S*bind.*)$@#osup-bind# \1@' /etc/fstab
  fi
  bgrun leapp-up-$TGT "leapp upgrade"
  grep -E "Errors:|Inhibitors:|Reboot the system" $K/leapp-up-$TGT.log
  grep -A6 "following errors" $K/leapp-up-$TGT.log
  grep -q "Reboot the system" $K/leapp-up-$TGT.log && echo "== 就绪。下一步: hop.sh reboot（重启前确认控制台 VNC/串口可用）"
  ;;

report)
  R=$LL/leapp-report.json; [ -f $R ] || { echo "无报告"; exit 1; }
  PYTHONIOENCODING=utf-8 $PY - "$R" <<'EOF'   # LC_ALL=C 下 py3.6 的 stdout 是 ascii；py2 需要 coding 声明
# -*- coding: utf-8 -*-
from __future__ import print_function, unicode_literals
import json, sys
r = json.load(open(sys.argv[1]))
inh, other = [], []
for e in r.get("entries", []):
    f = e.get("flags", []) + e.get("groups", [])
    if "inhibitor" in f or "error" in f: inh.append(e)
    elif e.get("severity") in ("high", "medium"): other.append(e)
print("== 阻断项/错误: %d" % len(inh))
for e in inh:
    print("\n[X] " + e["title"])
    print("    " + e.get("summary", "")[:900].replace("\n", "\n    "))
    for rem in e.get("detail", {}).get("remediations", []):
        c = rem.get("context")
        print("    -> %s: %s" % (rem.get("type"), " ".join(c) if isinstance(c, list) else c))
print("\n== 高/中风险提示:")
for e in other: print("  [%s] %s" % (e["severity"], e["title"]))
for e in other:
    if "not signed" in e["title"]:
        print("\n== 非官方签名的包（升级时不处理，依赖断了可能被删）:\n  " + e.get("summary", "").split(":", 1)[-1].strip().replace("\n", " "))
EOF
  echo; echo "== 未回答的问题:"; grep -B1 -E "^# *confirm *=" $LL/answerfile 2>/dev/null | grep -E "^\[|confirm" || echo "  (无)"
  L=$LL/leapp-preupgrade.log; [ -f $LL/leapp-upgrade.log ] && [ $LL/leapp-upgrade.log -nt $L ] && L=$LL/leapp-upgrade.log
  echo; echo "== 事务规模:"; grep -E "dnf_transaction_check: (Install|Upgrade|Remove|Downgrade) +[0-9]+ Package" $L | sed 's/.*_check://' | tail -4
  echo "== 将被删除的包（逐个确认没有业务依赖！）:"
  awk '/dnf_transaction_check: Removing( dependent packages)?:/{f=1;next} f&&/dnf_transaction_check: [A-Z]/{f=0} f' $L | sed 's/.*_check://' | awk 'NF>3{print $1}' | sort -u | tr '\n' ' '; echo
  echo "== 关键包去向:"; grep -E "dnf_transaction_check: +(docker-ce|containerd\.io|kubectl|openssh-server|kernel|nginx|httpd|php|mariadb-server|postgresql-server|java-[0-9.]+-openjdk|python3|cloud-init|NetworkManager) " $L | sed 's/.*_check://' | awk '{print "  "$1, $3, ($4=="@System" ? "<<< 将被删除" : $4)}' | sort -u
  ;;

answer)
  # 7→8：floppy/pata_acpi 若又被加载（旧 initramfs 在黑名单之前构建），先卸载
  if [ "$CUR" = 7 ]; then for m in floppy pata_acpi; do lsmod | grep -q "^$m " && rmmod "$m" && echo "rmmod $m"; done; fi
  grep -q "remove_pam_pkcs11_module_check" $LL/answerfile 2>/dev/null && leapp answer --section remove_pam_pkcs11_module_check.confirm=True && echo "pam_pkcs11 → True"
  if grep -q "check_vdo" $LL/answerfile 2>/dev/null; then
    if lsblk -o FSTYPE,TYPE 2>/dev/null | grep -qi vdo; then echo "!! 存在 VDO 设备，不能自动确认 check_vdo，需人工处理"
    else $PKG -y install vdo >/dev/null 2>&1; leapp answer --section check_vdo.confirm=True && echo "check_vdo → True（已确认无 VDO 设备）"; fi
  fi
  # 8→9：firewalld AllowZoneDrifting 已在 EL9 移除，EL9 的行为等同于 no。只改配置、不 reload（reload 可能清掉 docker 的 iptables 链）
  if [ "$CUR" = 8 ] && grep -qE "^AllowZoneDrifting=yes" /etc/firewalld/firewalld.conf 2>/dev/null; then
    cp -a /etc/firewalld/firewalld.conf "$K/firewalld.conf.bak" && sed -i 's/^AllowZoneDrifting=.*/AllowZoneDrifting=no/' /etc/firewalld/firewalld.conf && echo "firewalld AllowZoneDrifting → no（未 reload，重启后生效）"
  fi
  # 9→10：EL10 没有 dhclient，NM 配置里的 dhcp=dhclient 是阻断项（Aliyun 等老镜像会带）。/etc 里的注释掉；/usr/lib 下不属于任何包的残留文件挪走
  if [ "$CUR" = 9 ]; then
    for f in $(grep -rl "^dhcp *= *dhclient" /etc/NetworkManager /usr/lib/NetworkManager/conf.d 2>/dev/null); do
      case "$f" in
        /etc/*) cp -a "$f" "$K/$(basename "$f").bak" && sed -i 's/^dhcp *= *dhclient/#&  # removed for EL10 (no dhclient)/' "$f" && echo "注释 dhcp=dhclient: $f";;
        *) rpm -qf "$f" >/dev/null 2>&1 && echo "!! $f 属于 $(rpm -qf "$f")，请人工处理" || { mv "$f" "$K/" && echo "挪走残留 $f";} ;;
      esac
    done
  fi
  # 9→10：ifcfg 旧网络配置 → NetworkManager keyfile（只改存储格式，不重连；迁移前后对比地址和默认路由）
  # 8→9 也可能需要：老镜像的 ifcfg 缺 TYPE=Ethernet，leapp 报 "Network configuration for unsupported device types"（NM ≥1.38 才有 migrate）
  if [ "$CUR" -ge 8 ] && ls /etc/sysconfig/network-scripts/ifcfg-* >/dev/null 2>&1 && nmcli connection migrate --help >/dev/null 2>&1      && { [ "$CUR" = 9 ] || grep -q "unsupported device types" $LL/leapp-report.txt 2>/dev/null; }; then
    before=$(ip -4 -o addr show scope global | awk '{print $2,$4}' | sort; ip route show default)
    cp -a /etc/sysconfig/network-scripts "$K/network-scripts.bak.$(date +%s)"
    # 手工留下的备份副本（ifcfg-eth0.bak 等）不是有效配置，NM 迁移不了，leapp 会一直报阻断 → 挪到工具目录（真实踩坑）
    for f in /etc/sysconfig/network-scripts/ifcfg-*; do
      [ -e "$f" ] || continue
      case "$f" in *.bak|*.backup|*.orig|*.old|*.save|*.rpmsave|*.rpmnew|*~|*.bak[0-9]*|*-bak*) mkdir -p "$K/ifcfg-backups"; mv "$f" "$K/ifcfg-backups/"; echo "挪走 ifcfg 备份副本: $f";; esac
    done
    nmcli connection migrate 2>&1 | tail -3
    after=$(ip -4 -o addr show scope global | awk '{print $2,$4}' | sort; ip route show default)
    if [ "$before" = "$after" ]; then echo "ifcfg → keyfile 迁移完成，地址/默认路由不变"; else echo "!! 迁移前后网络有变化，立即检查:"; echo "$before"; echo "---"; echo "$after"; fi
    ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v "ifcfg-lo$" | grep . && echo "!! 仍有 ifcfg 文件未迁移（ifcfg-lo 除外）"
  fi
  grep -B1 -E "^# *confirm *=" $LL/answerfile 2>/dev/null | grep "^\[" | sed 's/^/仍未回答: /'
  ;;

reboot)
  shift
  grep -q "Reboot the system" $K/leapp-up-$TGT.log 2>/dev/null || echo "WARN: 没看到本跳 leapp upgrade 成功的输出，确认是升级重启还是普通重启"
  NOSTOP=0; [ "$1" = --no-stop ] && { NOSTOP=1; shift; echo "--no-stop：不提前停止任何容器"; }
  # K8s 节点：先停 kubelet 并有序停止 pod 容器，否则 kubelet 会在关机途中把容器重新拉起
  [ $NOSTOP = 0 ] && systemctl is-active kubelet >/dev/null 2>&1 && bash "$(dirname "$0")/k8s.sh" stop
  [ $NOSTOP = 0 ] && stop_stateful "$@"
  # fstab 的 NFS 被 k8s.sh nfs-off 临时注释时（非 K8s 主机）：mask docker。只 disable 不够——升级事务里 docker-ce 被升级后
  # 会重新启用，开机时容器抢在 NFS 恢复之前启动，业务目录绑到空的本地目录（真实踩坑）。k8s.sh nfs-on 挂好 NFS 后再 unmask 启动
  if grep -q '^#osup-nfs# ' /etc/fstab 2>/dev/null && ! systemctl cat kubelet >/dev/null 2>&1 && systemctl cat docker.service >/dev/null 2>&1; then
    systemctl mask docker.service docker.socket >/dev/null 2>&1 && touch "$K/docker-masked-for-nfs" && \
      echo "NFS 已临时下线：docker 已 mask，重启后先执行 k8s.sh nfs-on（挂好 NFS 再 unmask/启动 docker）"
  fi
  sync; systemd-run --on-active=5 /usr/bin/systemctl reboot >/dev/null 2>&1 && echo "5 秒后重启。本机执行 remote.py HOST wait-ssh 等待；超时就去控制台 VNC/串口看（见 references/recovery.md）"
  ;;

post)
  M=${2:?需要 MIRROR}; PREV=$((CUR-1))
  echo "== 现在: $(cat /etc/redhat-release)  kernel $(uname -r)"
  if [ -e /root/tmp_leapp_py3/.leapp_upgrade_failed ]; then
    echo "!! 发现 leapp 失败标记：升级在 initramfs 阶段出过错（系统可能是'半升级'状态），先按 references/recovery.md 排查，不要直接继续"
    grep -E "install failed|erase failed|scriptlet failed|rror unpacking" $LL/leapp-upgrade.log | head -10; exit 1
  fi
  uname -r | grep -q "el$CUR" || echo "WARN: 运行内核不是 el$CUR，检查 grub 默认项"
  # 关键：等 leapp 的首次启动阶段（leapp_resume.service，FirstBoot 收尾）跑完再清理。
  # 真实踩坑：SSH 一恢复就删 leapp，正在运行的 removeleftoverpackages 报 ModuleNotFoundError，FirstBoot 中断
  t=0; while [ $t -lt 1800 ]; do
    st=$(systemctl show -p ActiveState --value leapp_resume.service 2>/dev/null)
    case "$st" in active|activating|reloading) [ $((t % 60)) = 0 ] && echo "  等待 leapp_resume.service 完成（$st，${t}s）"; sleep 10; t=$((t+10));; *) break;; esac
  done
  if [ "$(systemctl show -p ActiveState --value leapp_resume.service 2>/dev/null)" = failed ]; then
    echo "WARN: leapp_resume.service 失败（leapp 首次启动收尾没完成），日志："; journalctl -u leapp_resume -b --no-pager -o cat 2>/dev/null | grep -E "Error|ERROR|failed" | tail -5
    echo "      本脚本会接着清理残留包/内核；检查报告 $LL/leapp-report.txt 里 FirstBoot 阶段的条目"
  fi
  systemctl disable leapp_resume.service >/dev/null 2>&1; rm -f /etc/systemd/system/leapp_resume.service; systemctl daemon-reload; systemctl reset-failed leapp_resume.service 2>/dev/null
  clear_leapp_excludes
  rpm -qa | grep -E "^(leapp|python[23]?-leapp|snactor|elevate-release|leapp-upgrade|leapp-data|leapp-deps|leapp-repository|kernel-workaround)" | xargs -r rpm -e --nodeps
  rm -rf /var/lib/leapp/el*userspace /var/lib/leapp/scratch /root/tmp_leapp_py3 /etc/leapp/files /etc/yum.repos.d/ELevate.repo
  # 下面的 dnf 事务可能升级 docker-ce/containerd → dockerd 重启，容器只给 10s 就被 SIGKILL：先优雅停有状态容器
  stop_stateful
  oldk=$(rpm -qa 'kernel*' | grep -E "\.el${PREV}(_[0-9]+)?\.")
  [ -n "$oldk" ] && { echo "删除旧内核: $(echo $oldk | wc -w) 个包"; $PKG -y remove $oldk 2>&1 | tail -1; }
  # EL7 内核的 %preun 调用 new-kernel-pkg（EL8 上没有，exit 127）→ dnf 删不掉：不跑脚本强删，再清理 /boot 和启动项
  left=$(rpm -qa 'kernel*' | grep -E "\.el${PREV}(_[0-9]+)?\.")
  if [ -n "$left" ]; then
    echo "以 --noscripts 删除残留旧内核: $left"; rpm -e --noscripts --nodeps $left
    for v in $(echo "$left" | grep -E "^kernel(-core)?-[0-9]" | sed -E 's/^kernel(-core)?-//'); do
      rm -rf "/boot/vmlinuz-$v" "/boot/initramfs-$v.img" "/boot/initramfs-${v}kdump.img" "/boot/System.map-$v" "/boot/config-$v" "/boot/symvers-$v.gz" "/boot/.vmlinuz-$v.hmac" "/lib/modules/$v"
      rm -f /boot/loader/entries/*"$v".conf
    done
    command -v grub2-mkconfig >/dev/null && [ -f /boot/grub2/grub.cfg ] && [ ! -d /boot/loader/entries ] && grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
    echo "默认内核: $(grubby --default-kernel 2>/dev/null)"
  fi
  for e in /boot/loader/entries/*.conf; do k=$(awk '/^linux/{print $2}' "$e"); [ -n "$k" ] && [ ! -e "/boot${k#/boot}" ] && [ ! -e "$k" ] && { echo "删除失效启动项 $e"; rm -f "$e"; }; done
  cd /etc/yum.repos.d && mkdir -p disabled-for-upgrade
  mv ./*.rpmsave disabled-for-upgrade/ 2>/dev/null
  for f in ./*.rpmnew; do [ -e "$f" ] && { cp -a "${f%.rpmnew}" "disabled-for-upgrade/$(basename "${f%.rpmnew}").el$PREV" 2>/dev/null; mv -f "$f" "${f%.rpmnew}"; }; done
  # 指向旧版本的残留 repo（硬编码 /7/ /8/ /9/ 或 el7/el8/el9 的第三方源）挪走
  for f in ./*.repo; do grep -qE "^baseurl=.*(/|el|centos)${PREV}(/|\b)" "$f" && ! grep -qE '\$releasever' "$f" && { echo "挪走硬编码 EL$PREV 的源: $f"; mv "$f" disabled-for-upgrade/; }; done
  [ -f elrepo.repo ] && mv elrepo.repo disabled-for-upgrade/
  EPELS=""; for f in /etc/yum.repos.d/epel*.repo; do [ -e "$f" ] || continue; case "$f" in *cisco-openh264*) ;; *) EPELS="$EPELS $f";; esac; done
  # shellcheck disable=SC2086
  rewrite_mirrors "$M" /etc/yum.repos.d/almalinux*.repo $EPELS /etc/yum.repos.d/docker-ce.repo
  # EPEL Modular（EL8）上游已退役，镜像站多半没有：保留但允许不可用，避免 makecache 失败/卡住
  for f in /etc/yum.repos.d/epel*modular*.repo; do [ -e "$f" ] && grep -q "^skip_if_unavailable" "$f" || { [ -e "$f" ] && sed -i '/^\[/a skip_if_unavailable=1' "$f"; }; done
  # epel-cisco-openh264 只有 metalink（codecs.fedoraproject.org，国内常不可达）、镜像站也没有：关掉，避免 dnf 报 Cannot find a valid baseurl
  [ -f epel-cisco-openh264.repo ] && sed -i 's/^enabled=1/enabled=0/' epel-cisco-openh264.repo
  cd - >/dev/null || true
  $PKG clean all >/dev/null; $PKG makecache 2>&1 | grep -iE "error|fail|Metadata cache" | head -5
  bgrun dnfup-el$CUR "$PKG -y upgrade --nobest" || echo "!! dnf upgrade 失败，见 $K/dnfup-el$CUR.log（升级本身已完成，但需要处理后再进入下一跳）"
  tail -3 $K/dnfup-el$CUR.log
  left=$(rpm -qa | grep -E "\.el${PREV}(_[0-9]+)?\." | grep -v gpg-pubkey)
  echo "== 残留 el$PREV 包: $(echo $left | wc -w)"; echo "$left" | head -30
  # EL7 的 SCL（rh-ruby23/rh-php72/devtoolset/llvm-toolset，装在 /opt/rh）leapp 不处理，是 RSA/SHA1 签名 → 8→9 阻断
  # "Detected RPMs with RSA/SHA1 signature"。没有进程在用 /opt/rh 时直接删
  scl=$(rpm -qa --qf '%{NAME} %{RELEASE}\n' | awk '$2 ~ /el7/ && $1 ~ /^(rh-|devtoolset-|llvm-toolset-|centos-release-scl)/ {print $1}')
  if [ -n "$scl" ] && [ "$CUR" = 8 ]; then
    if ls -l /proc/[0-9]*/exe 2>/dev/null | grep -q ' /opt/rh/'; then echo "!! 有进程在用 /opt/rh 下的 SCL，没有删除: $(echo $scl)"
    else echo "删除 EL7 SCL 残留（8→9 的 SHA1 签名阻断项）: $(echo $scl | wc -w) 个"; $PKG -y remove $scl 2>&1 | tail -1; fi
  fi
  # 阿里云等老镜像的 cloud-init 是源码安装的（不属于 rpm），依赖旧 python，升级后每跳都 failed：禁用并挪走这些 unit
  if ! rpm -q cloud-init >/dev/null 2>&1; then
    for u in cloud-init-local cloud-init cloud-config cloud-final; do
      f=$(systemctl show -p FragmentPath --value $u.service 2>/dev/null)
      [ -n "$f" ] && [ -e "$f" ] && ! rpm -qf "$f" >/dev/null 2>&1 && { systemctl disable $u.service >/dev/null 2>&1; mkdir -p "$K/cloud-init-units"; mv "$f" "$K/cloud-init-units/"; echo "挪走源码安装的 cloud-init unit: $f"; }
    done
    systemctl daemon-reload; systemctl reset-failed 2>/dev/null
  fi
  # 到达 EL10（最后一跳）后恢复 up 时临时注释的 bind 挂载
  if [ "$CUR" -ge 10 ] && grep -q "^#osup-bind# " /etc/fstab; then
    sed -i -E 's/^#osup-bind# //' /etc/fstab; systemctl daemon-reload; mount -a 2>&1 | head -3; echo "已恢复 fstab bind 挂载（#osup-bind#）"
  fi
  start_stateful
  echo "== failed units:"; systemctl --failed --no-legend --no-pager
  df -h / | tail -1
  ;;

status)
  for f in $(ls -t $K/leapp-*.log 2>/dev/null | head -1); do echo "$f:"; grep -v '^\s*$' "$f" | tail -5; done
  pgrep -af "[l]eapp (pre)?upgrade" | head -2 ;;

*) sed -n '2,14p' "$0";;
esac
