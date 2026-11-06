#!/bin/bash
# convert-el8.sh - CentOS Linux 8 / CentOS Stream 8 → AlmaLinux 8（同大版本转换），之后用 hop.sh 走 8→9→10
#
# ELevate 不支持以 CentOS Linux 8 为源，必须先用 AlmaLinux 官方的 almalinux-deploy 转成 AlmaLinux 8。
#
#   bash convert-el8.sh prep <MIRROR>                       修源（CentOS 8 → vault，EPEL 改成 EPEL8）、pip 冲突、多余 kernel-devel
#   bash convert-el8.sh update                               后台 dnf upgrade 到 CentOS 8.5（almalinux-deploy 要求 ≥8.4；不用它的 -f，
#                                                            因为 -f 会把 repo 改到海外 rackspace vault 且要求特定文件名）
#   bash convert-el8.sh run  <MIRROR> [almalinux-deploy.sh]  后台执行官方 almalinux-deploy（-d 允许从 Stream 降级；-l 用镜像）并等待
#   bash convert-el8.sh post                                 重启进入 AlmaLinux 内核后：确认版本、删非 AlmaLinux 内核、dnf upgrade
#
# almalinux-deploy.sh：服务器若访问不了 GitHub，先在本机下载
#   https://raw.githubusercontent.com/AlmaLinux/almalinux-deploy/master/almalinux-deploy.sh
# 再用 remote.py put 上传，第三个参数传入路径。
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
K=/root/os-upgrade-kit; mkdir -p "$K"
[ "$(rpm -E %rhel)" = 8 ] || { echo "只用于 EL8（当前 el$(rpm -E %rhel)）"; exit 1; }
ID=$(. /etc/os-release; echo "$ID")

bgrun() { # bgrun <name> <cmd>：systemd-run 后台执行，等待结束
  local log=$K/$1.log t=0; rm -f "$log"
  systemd-run --unit="osup-$1-$(date +%s)" /bin/bash -c "$2 > $log 2>&1; echo __RC=\$? >> $log" >/dev/null
  echo "后台任务 $1 已启动，日志 $log"
  until grep -q "^__RC=" "$log" 2>/dev/null; do sleep 15; t=$((t+15)); [ $((t % 180)) = 0 ] && echo "  ...${t}s $(grep -v '^\s*$' "$log" | tail -1 | cut -c1-110)"; done
  local rc; rc=$(sed -n 's/^__RC=//p' "$log" | tail -1); echo "__RC=${rc:-?}"; return "${rc:-1}"   # 把后台命令的退出码传出去
}

case "$1" in
prep)
  M=${2:?需要 MIRROR}; [ "$ID" = almalinux ] && { echo "已经是 AlmaLinux"; exit 0; }
  if [ "$M" = upstream ]; then V=https://vault.centos.org; E=https://dl.fedoraproject.org/pub/epel; else V=$M/centos-vault; E=$M/epel; fi
  if grep -qi stream /etc/redhat-release; then VP=8-stream; else VP=8.5.2111; fi
  curl -sfI -m 15 "$V/$VP/BaseOS/x86_64/os/repodata/repomd.xml" >/dev/null || { echo "vault 不可达: $V/$VP"; exit 1; }
  D=/etc/yum.repos.d; mkdir -p $D/disabled-for-upgrade; cp -a $D "$K/yum.repos.d.orig.$(date +%s)"
  for f in $D/*.repo; do
    case "$(basename "$f")" in docker-ce.repo) continue;; esac
    grep -qiE '^\[(base|baseos|appstream|extras|powertools|centosplus|epel[a-z-]*)\]|centos|/epel/' "$f" && mv "$f" $D/disabled-for-upgrade/
  done
  mv $D/*.rpmnew $D/disabled-for-upgrade/ 2>/dev/null
  cat > $D/CentOS-Vault-8.repo <<EOF
[c8vault-baseos]
name=CentOS 8 vault - BaseOS
baseurl=$V/$VP/BaseOS/\$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
[c8vault-appstream]
name=CentOS 8 vault - AppStream
baseurl=$V/$VP/AppStream/\$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
[c8vault-extras]
name=CentOS 8 vault - extras
baseurl=$V/$VP/extras/\$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOF
  if rpm -q epel-release >/dev/null 2>&1; then  # 常见错误配置：EL8 上配着 EPEL 7
    printf "[epel]\nname=EPEL 8\nbaseurl=%s/8/Everything/\$basearch/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-8\n" "$E" > $D/epel.repo
  fi
  [ -f $D/docker-ce.repo ] && [ "$M" != upstream ] && sed -i -E "s#https?://download\.docker\.com#$M/docker-ce#" $D/docker-ce.repo
  dnf clean all >/dev/null; dnf -q makecache 2>&1 | tail -3; dnf repolist 2>&1 | tail -8
  # pip 冲突
  P=$K/python-unowned-el8-$(date +%s); n=0
  for d in /usr/lib/python3.6/site-packages /usr/lib64/python3.6/site-packages /usr/lib/python2.7/site-packages /usr/lib64/python2.7/site-packages; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do [ -e "$f" ] || continue; rpm -qf "$f" >/dev/null 2>&1 || { mkdir -p "$P$d"; mv "$f" "$P$d/"; n=$((n+1)); }; done
  done; echo "pip 冲突清理：挪走 $n 个文件 ${n:+→ $P}"
  # 多余 kernel-devel（leapp 8→9 也会阻断）
  cur=$(uname -r); extra=$(rpm -q kernel-devel 2>/dev/null | grep -v "not installed" | grep -v "${cur%.x86_64}")
  [ -n "$extra" ] && dnf -y remove $extra 2>&1 | tail -1
  df -h / /var | tail -n +2
  echo "完成。下一步: convert-el8.sh update，然后 convert-el8.sh run $M <almalinux-deploy.sh 路径>" ;;

update)
  echo "当前: $(cat /etc/redhat-release)"
  if ! bgrun dnfup-centos8 "dnf -y upgrade --exclude='docker*' --exclude='containerd*'"; then
    grep -E "^(Error|Problem|  - )" "$K/dnfup-centos8.log" | head -15
    echo "!! dnf upgrade 失败（见 $K/dnfup-centos8.log），不要继续 run：先解决依赖问题"; exit 1
  fi
  echo "现在: $(cat /etc/redhat-release)"
  grep -qE "release 8\.[4-9]" /etc/redhat-release || { echo "!! 仍低于 8.4，almalinux-deploy 会拒绝转换"; exit 1; } ;;

run)
  M=${2:?需要 MIRROR}; S=${3:-$K/almalinux-deploy.sh}
  grep -qE "release 8\.[4-9]|Stream" /etc/redhat-release || { echo "!! almalinux-deploy 要求 ≥8.4，先 convert-el8.sh update"; exit 1; }
  if [ ! -s "$S" ]; then curl -fsSL -m 60 -o "$S" https://raw.githubusercontent.com/AlmaLinux/almalinux-deploy/master/almalinux-deploy.sh || { echo "下载失败：在本机下载后上传到 $S"; exit 1; }; fi
  echo "almalinux-deploy.sh sha256: $(sha256sum "$S" | cut -d' ' -f1)（与上游对照）"
  # 关键：vault 源必须在转换前移走。它不属于任何 rpm，almalinux-deploy 不会删它；
  # 若 repo id 与 AlmaLinux 的 baseos/appstream 冲突，distro-sync 会同步回 CentOS，什么也没换（真实踩坑）
  mkdir -p /etc/yum.repos.d/disabled-for-upgrade; mv /etc/yum.repos.d/CentOS-Vault-8.repo /etc/yum.repos.d/disabled-for-upgrade/ 2>/dev/null
  opt="-d"; [ "$M" != upstream ] && opt="$opt -l=$M/almalinux"
  bgrun almalinux-deploy "bash $S $opt" || echo "!! almalinux-deploy 返回非 0"
  grep -E "OK|ERROR|Error|error|reboot|Migration" "$K/almalinux-deploy.log" | tail -25
  grep -q "^__RC=0" "$K/almalinux-deploy.log" && echo "== 转换完成。用 hop.sh reboot 重启进入 AlmaLinux 内核，然后 convert-el8.sh post" ;;

post)
  cat /etc/redhat-release; uname -r
  [ "$ID" = almalinux ] || { echo "!! 还不是 AlmaLinux"; exit 1; }
  uname -r | grep -q "el8_" || echo "WARN: 运行内核看起来不是 AlmaLinux 的，检查 grubby --default-kernel"
  cent=$(rpm -qa --qf '%{VENDOR}\n' | grep -c CentOS)
  if [ "$cent" -gt 20 ]; then
    echo "!! 仍有 $cent 个 CentOS 包：distro-sync 没生效。检查 dnf repolist 是否只有 AlmaLinux 源（不能有同名的 CentOS 源），然后执行:"
    echo "   dnf -y distro-sync --allowerasing && grubby --set-default=\$(ls -t /boot/vmlinuz-*el8*.x86_64 | head -1) 再重启"; exit 1
  fi
  nonalma=$(rpm -qa 'kernel*' --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} %{VENDOR}\n' | grep -v AlmaLinux | awk '{print $1}' | grep -v "$(uname -r)")
  [ -n "$nonalma" ] && { echo "删除非 AlmaLinux 内核: $(echo $nonalma | wc -w) 个包"; dnf -y remove $nonalma 2>&1 | tail -1; }
  echo "== 非 AlmaLinux 厂商的包:"; rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{VENDOR}\n' | grep -viE "AlmaLinux|gpg-pubkey" | sort
  bgrun dnfup-alma8 "dnf -y upgrade --nobest" || { tail -15 "$K/dnfup-alma8.log"; echo "!! dnf upgrade 失败"; exit 1; }; tail -2 "$K/dnfup-alma8.log"
  echo "下一步: hop.sh prep <MIRROR>（8→9）" ;;

*) sed -n '2,13p' "$0";;
esac
