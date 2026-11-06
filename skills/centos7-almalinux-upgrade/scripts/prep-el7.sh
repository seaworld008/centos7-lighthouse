#!/bin/bash
# prep-el7.sh - CentOS 7 上的升级前准备（分步执行，每步看结果再下一步）
#
#   bash prep-el7.sh repos   <MIRROR>   # 统一 CentOS7/EPEL7/docker 源到可用镜像（CentOS 7 已 EOL，官方源已下线）
#   bash prep-el7.sh update             # 后台 yum update 到 7.9（排除 docker/containerd/openssh），等待完成
#   bash prep-el7.sh pipfix             # 挪走 pip 装的、不属于 rpm 的 site-packages，并修复被覆盖的 python rpm
#   bash prep-el7.sh inhibitors         # 处理已知 7→8 阻断项（驱动/kernel-devel/旧内核/mysql-libs/pam_pkcs11）
#
# MIRROR 取值（基础 URL，下面拼 /centos-vault /epel-archive /almalinux /epel /docker-ce）：
#   https://mirrors.aliyun.com          阿里云公网（国内通用，实测最稳）
#   http://mirrors.cloud.aliyuncs.com   阿里云 ECS 内网（不走公网流量）
#   https://repo.huaweicloud.com        华为云（实测会 429 限流，不稳就换阿里云）
#   https://mirrors.tuna.tsinghua.edu.cn
#   upstream                            海外（AWS 等）：用 vault.centos.org / archives.fedoraproject.org / 官方源
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BK=/root/os-upgrade-kit/bak; mkdir -p "$BK"
[ "$(rpm -E %rhel)" = 7 ] || { echo "这不是 EL7（当前 el$(rpm -E %rhel)），prep-el7.sh 只用于 CentOS 7"; exit 1; }

bgrun() { # bgrun <name> <cmd...>  用 systemd-run 后台执行并等待（不受 SSH 断线影响）
  local name=$1; shift; local log=/root/os-upgrade-kit/$name.log
  rm -f "$log"; systemd-run --unit="osup-$name-$(date +%s)" /bin/bash -c "$* > $log 2>&1; echo __RC=\$? >> $log" >/dev/null
  echo "后台任务 $name 已启动，日志 $log"
  local t=0; until grep -q "^__RC=" "$log" 2>/dev/null; do sleep 10; t=$((t+10)); [ $((t % 120)) = 0 ] && echo "  ...${t}s $(tail -1 "$log" 2>/dev/null | cut -c1-100)"; done
  tail -5 "$log"
  local rc; rc=$(sed -n 's/^__RC=//p' "$log" | tail -1); echo "__RC=${rc:-?}"; return "${rc:-1}"   # 把后台命令的退出码传出去
}

repo_ok() { curl -sfI -m 15 "$1/repodata/repomd.xml" >/dev/null 2>&1; }

case "$1" in
repos)
  M=${2:?需要 MIRROR 参数}
  if [ "$M" = upstream ]; then C7=https://vault.centos.org/7.9.2009; E7=https://archives.fedoraproject.org/pub/archive/epel/7; DK=https://download.docker.com
  else C7=$M/centos-vault/7.9.2009; E7=$M/epel-archive/7; DK=$M/docker-ce; fi
  repo_ok "$C7/os/x86_64" || { echo "镜像不可用: $C7/os/x86_64 ，换一个 MIRROR"; exit 1; }
  mkdir -p /etc/yum.repos.d/disabled-for-upgrade; cp -a /etc/yum.repos.d "$BK/yum.repos.d.orig.$(date +%s)"
  # 所有 CentOS 官方 repo 文件（含各种改名副本/重复定义）全部挪走，换成一个统一文件
  for f in /etc/yum.repos.d/*.repo; do
    case "$(basename "$f")" in docker-ce.repo) continue;; esac
    grep -qiE '^\[(base|updates|extras|centosplus|contrib|fasttrack|cr|epel)\]|mirrorlist\.centos\.org|/centos/(\$releasever|7)/(os|updates|extras)|centos-vault|/epel/' "$f" && mv "$f" /etc/yum.repos.d/disabled-for-upgrade/
  done
  mv /etc/yum.repos.d/*.bak /etc/yum.repos.d/*.backup /etc/yum.repos.d/disabled-for-upgrade/ 2>/dev/null
  cat > /etc/yum.repos.d/CentOS-Base.repo <<EOF
[base]
name=CentOS-7.9.2009 - Base
baseurl=$C7/os/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[updates]
name=CentOS-7.9.2009 - Updates
baseurl=$C7/updates/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[extras]
name=CentOS-7.9.2009 - Extras
baseurl=$C7/extras/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF
  if rpm -q epel-release >/dev/null 2>&1; then
    if repo_ok "$E7/x86_64"; then
      printf "[epel]\nname=EPEL 7 (archive)\nbaseurl=%s/\$basearch/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7\n" "$E7" > /etc/yum.repos.d/epel.repo
    else echo "WARN: EPEL7 归档 $E7 不可用，EPEL 暂时不启用"; fi
  fi
  [ -f /etc/yum.repos.d/docker-ce.repo ] && sed -i -E "s#https?://download\.docker\.com#$DK#" /etc/yum.repos.d/docker-ce.repo
  # 其它第三方源：逐个探测，不可用的禁用（否则 yum/leapp 会卡住或失败）
  yum clean all >/dev/null 2>&1
  for id in $(yum repolist enabled 2>/dev/null | awk 'f&&NF>1{sub(/^!/,"",$1); sub(/\/.*/,"",$1); print $1} /^repo id/{f=1}' | grep -vE "^(base|updates|extras|epel|repolist:)$"); do
    if ! timeout 60 yum -q --disablerepo='*' --enablerepo="$id" makecache fast >/dev/null 2>&1; then
      echo "禁用不可用的源: $id"; yum-config-manager --disable "$id" >/dev/null 2>&1 || sed -i "/^\[$id\]/,/^\[/ s/^enabled=1/enabled=0/" /etc/yum.repos.d/*.repo
    fi
  done
  yum repolist enabled 2>&1 | tail -12
  ;;

update)
  echo "当前: $(cat /etc/redhat-release)"
  bgrun yum7update "yum -y update --exclude='docker*' --exclude='containerd*' --exclude='openssh*'" || echo "!! yum update 返回非 0（个别包失败时也会这样，看下面的 Failed 段）"
  grep -E "^(Failed|Error|error:)" -A3 /root/os-upgrade-kit/yum7update.log | head -20
  echo "现在: $(cat /etc/redhat-release)；有 Failed 的包通常是 pip 文件冲突 → 运行 pipfix 后重装该包"
  ;;

pipfix)
  D=/root/os-upgrade-kit/python-unowned-$(date +%s); mkdir -p "$D"; n=0
  for d in /usr/lib/python2.7/site-packages /usr/lib64/python2.7/site-packages /usr/lib/python3.6/site-packages /usr/lib64/python3.6/site-packages; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do [ -e "$f" ] || continue; rpm -qf "$f" >/dev/null 2>&1 || { mkdir -p "$D$d"; mv "$f" "$D$d/"; n=$((n+1)); }; done
  done
  echo "挪走 $n 个不属于 rpm 的文件 → $D （需要时可还原）"
  # 被 pip 覆盖过文件的 python rpm：重新安装恢复（rpm -V 报 5/S 改动的）
  bad=$(for p in $(rpm -qa 'python*' --qf '%{NAME}\n'); do rpm -V "$p" 2>/dev/null | grep -qE "^(..5|S|missing)" && echo "$p"; done | sort -u)
  [ -n "$bad" ] && { echo "重装被覆盖/缺失文件的包: $bad"; yum -y reinstall $bad 2>&1 | tail -3; }
  # 之前 yum update 因文件冲突没装上的包（日志里 "Failed:" 段，如 python-urllib3），现在补装
  failed=$(awk '/^Failed:/{f=1;next} f&&NF==0{f=0} f{print $1}' /root/os-upgrade-kit/yum7update.log 2>/dev/null | sed -E 's/\.(noarch|x86_64|i686)$//; s/-[0-9][^-]*-[^-]*$//' | sort -u)
  [ -n "$failed" ] && { echo "补装之前失败的包: $failed"; yum -y install $failed 2>&1 | tail -2; }
  python -c "import yum" && echo "yum python 模块 OK"
  ;;

inhibitors)
  echo "--- 1. 已移除驱动"; for m in floppy pata_acpi; do lsmod | grep -q "^$m " && { rmmod $m && echo "rmmod $m"; }; echo "blacklist $m" ; done > /etc/modprobe.d/leapp-removed-drivers.conf; cat /etc/modprobe.d/leapp-removed-drivers.conf
  echo "--- 2. 多余 kernel-devel / 旧内核"
  cur=$(uname -r); extra=$(rpm -q kernel-devel 2>/dev/null | grep -v "not installed" | grep -v "${cur%.x86_64}")
  [ -n "$extra" ] && yum -y remove $extra 2>&1 | tail -1
  rpm -q yum-utils >/dev/null || yum -y install yum-utils >/dev/null 2>&1
  package-cleanup -y --oldkernels --count=1 2>&1 | tail -1; rpm -q kernel kernel-devel
  echo "--- 3. mysql-community-libs → mariadb-libs（保住 postfix 等依赖 libmysqlclient 的包）"
  ml=$(rpm -qa --qf '%{NAME}\n' | grep -E "^mysql(57|80)?-community-(libs|libs-compat|common|client|release)$|^mysql57-community-release$|^mysql80-community-release$")
  if [ -n "$ml" ]; then rem=""; for p in $ml; do rem="$rem $p"; done
    rpm -q mysql-community-server >/dev/null 2>&1 && echo "!! 宿主机装了 mysql-community-server，不要自动处理：先逻辑备份并与业务方确认方案" || \
    yum -y swap -- remove $rem -- install mariadb-libs 2>&1 | grep -E "Complete|Error|Remov" | tail -3
  fi
  rpm -q postfix mariadb-libs 2>&1 | tr '\n' ' '; echo
  echo "--- 4. 第三方 *-release 源包（7→8 用不上）"
  rpm -qa --qf '%{NAME}\n' | grep -E "^(webtatic-release|nginx-release-centos|ius-release|remi-release|elrepo-release|mysql[0-9]*-community-release)$" | xargs -r yum -y remove 2>&1 | tail -1
  echo "完成。下一步：hop.sh prep <MIRROR>（会再检查 pip 冲突、装 ELevate；pam_pkcs11 等问题由 hop.sh answer 回答）"
  ;;

*) sed -n '2,20p' "$0";;
esac
