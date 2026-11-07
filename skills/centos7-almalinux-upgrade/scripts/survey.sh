#!/bin/bash
# survey.sh - 升级前只读勘察（EL7~EL10 通用，不修改任何东西）
# 用法: bash survey.sh > survey.txt     （末尾 RISK FLAGS 段是重点）
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
FLAGS=""
flag() { FLAGS="${FLAGS}[$1] $2"$'\n'; }   # 级别: BLOCKER / HIGH / MEDIUM / INFO
sec()  { echo; echo "===== $* ====="; }
has()  { command -v "$1" >/dev/null 2>&1; }
MAJOR=$(rpm -E %rhel 2>/dev/null); MAJOR=${MAJOR:-0}

sec OS
cat /etc/redhat-release 2>/dev/null; echo "kernel=$(uname -r) arch=$(uname -m) el=$MAJOR"
echo "hostname=$(hostname)"; uptime
VIRT=$(systemd-detect-virt 2>/dev/null)
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null); PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
BIOSV=$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null)
CLOUD=unknown
case "$VENDOR $PRODUCT $BIOSV" in *Alibaba*) CLOUD=aliyun;; *Amazon*|*EC2*) CLOUD=aws;; *OpenStack*|*HUAWEI*|*Huawei*) CLOUD=huawei;; esac
[ -d /usr/local/aegis ] || [ -d /usr/local/share/aliyun-assist ] && CLOUD=aliyun
[ -d /usr/local/uniagent ] || [ -d /CloudResetPwdUpdateAgent ] || [ -d /usr/local/hostguard ] && CLOUD=huawei
[ -e /etc/amazon ] || rpm -q amazon-ssm-agent >/dev/null 2>&1 && CLOUD=aws
echo "virt=$VIRT dmi='$VENDOR / $PRODUCT' cloud=$CLOUD"
[ -d /sys/firmware/efi ] && echo "boot=UEFI" || echo "boot=BIOS"
[ "$(uname -m)" != "x86_64" ] && flag BLOCKER "架构 $(uname -m)：本技能只覆盖 x86_64"
[ "$MAJOR" = "7" ] && ! grep -q "7.9" /etc/redhat-release && flag INFO "当前非 7.9，ELevate 要求先 yum update 到 7.9"
OSID=$(. /etc/os-release 2>/dev/null; echo "$ID")
[ "$MAJOR" = 8 ] && [ "$OSID" != almalinux ] && flag BLOCKER "源系统是 $(cat /etc/redhat-release)：ELevate 不支持以 CentOS 8 为源，先用 convert-el8.sh 转成 AlmaLinux 8，再 hop.sh 8→9→10"

sec CPU
grep -m1 "model name" /proc/cpuinfo; echo "nproc=$(nproc)"
MISS=""
for f in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do grep -qw $f /proc/cpuinfo || MISS="$MISS $f"; done
if [ -n "$MISS" ]; then echo "x86-64-v3: NO (缺:$MISS)"; flag BLOCKER "CPU 不满足 x86-64-v3（缺$MISS）：AlmaLinux 10 标准版无法运行，只能升到 9，或用 AlmaLinux 10 x86_64_v2 变体"
else echo "x86-64-v3: YES"; fi

sec MEMORY/DISK
free -h; df -hT -x tmpfs -x devtmpfs -x overlay 2>/dev/null
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
grep -vE "^\s*#|^\s*$" /etc/fstab
VARFREE=$(df -Pm /var | awk 'NR==2{print $4}'); BOOTFREE=$(df -Pm /boot | awk 'NR==2{print $4}')
[ "${VARFREE:-0}" -lt 5000 ] && flag HIGH "/var 可用 ${VARFREE}MB < 5GB：leapp 下载+容器环境需要 3~5GB，先清理（docker 无用镜像、日志、yum 缓存）"
[ "${BOOTFREE:-0}" -lt 250 ] && flag HIGH "/boot 可用 ${BOOTFREE}MB < 250MB：先删旧内核 (package-cleanup --oldkernels --count=1)"
grep -qE '^[^#]\S*\s+/(sys|proc|dev|run)/\S*\s+\S+\s+\S*bind' /etc/fstab && flag BLOCKER "fstab 里有 bind 到 /sys|/proc|/dev|/run 的挂载（如阿里云 set_ecs_special.sh 的 eth0-speed.mock）：leapp 升级环境里挂不上直接进 emergency（shell 在串口，VNC 敲不了）。hop.sh up 会在 leapp upgrade 前自动注释，EL10 后恢复"
d=$(rpm -qa --qf '%{NAME}.%{ARCH}\n' 2>/dev/null | grep -vE '^(gpg-pubkey|kernel|kernel-devel|kernel-core|kernel-modules)\.' | sort | uniq -d | tr '\n' ' ')
[ -n "$d" ] && flag HIGH "rpm 库里有重复包（以前的 yum 事务没做完）：$d→ yum update 会报 multilib/保护版本错误。先 package-cleanup --cleandupes；删不掉的旧副本 rpm -e --justdb --nodeps，再 update 并 reinstall 这些包"
# 注意：bash 4.2（EL7）里 $( ) 内不能写 case 的 "pattern)"（括号不配对会解析失败），所以放进函数
manual_listeners() {
  local p
  for p in $(ps -eo pid=); do
    grep -q "session-[0-9]*\.scope" /proc/$p/cgroup 2>/dev/null || continue
    grep -qE "docker|kubepods" /proc/$p/cgroup 2>/dev/null && continue
    case "$(cat /proc/$p/comm 2>/dev/null)" in bash|sh|sshd|sudo|su|sleep|tail|ps|grep|top|screen|tmux*) continue;; esac
    ss -lntp 2>/dev/null | grep -q "pid=$p," && cat /proc/$p/comm
  done
}
mp=$(manual_listeners | sort | uniq -c | tr '\n' ' ')
[ -n "$mp" ] && flag HIGH "有手工从 SSH 会话启动、正在监听端口的服务进程（$mp）：重启后不会自己起来。backup.sh 会记录命令行/目录/环境变量，升级后 finalize.sh manual-procs 生成 systemd 服务"
grep -qE "\s(nfs|cifs|glusterfs)\s" /etc/fstab && flag MEDIUM "fstab 有网络文件系统：升级环境里可能挂载失败，升级前临时注释 noauto/nofail"
lsblk -o FSTYPE 2>/dev/null | grep -qi vdo && flag HIGH "存在 VDO 设备：8→9 前需转换为 LVM-VDO"
lsblk -o FSTYPE 2>/dev/null | grep -qi btrfs && flag BLOCKER "使用 btrfs：EL8+ 不支持 btrfs"

sec PACKAGES
echo "total rpm: $(rpm -qa | wc -l)"
echo "--- 非发行版厂商的包 (vendor 非 CentOS/AlmaLinux/Red Hat):"
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{VENDOR}\n' | grep -vE "CentOS|AlmaLinux|Red Hat|gpg-pubkey" | sort
echo "--- kernels:"; rpm -q kernel kernel-devel 2>/dev/null
KD=$(rpm -q kernel-devel 2>/dev/null | grep -vc "not installed"); [ "$KD" -gt 1 ] && flag HIGH "装了 $KD 个 kernel-devel（leapp 阻断项）：只留当前内核的那个"
echo "--- repos:"; ls /etc/yum.repos.d/
for f in /etc/yum.repos.d/*.repo; do grep -hoE "^\[[^]]+\]" "$f"; done | sort | uniq -d | sed 's/^/DUP repo id: /'
EPV=$(grep -hE "^(baseurl|metalink|mirrorlist)=" /etc/yum.repos.d/epel.repo 2>/dev/null | grep -oE "epel/[0-9]+|epel-[0-9]+" | grep -oE "[0-9]+" | head -1)
[ -n "$EPV" ] && [ "$EPV" != "$MAJOR" ] && flag HIGH "epel.repo 指向 EPEL $EPV，但系统是 EL$MAJOR：转换/升级时会拉错包，先改成 EPEL $MAJOR"
rpm -qa | grep -qiE "^(php[0-9]*w|php7[0-9]w|php5[0-9]w)-" && flag HIGH "PHP 来自 webtatic（EL8+ 无此源）：确认是否还用；要用就改 remi 或容器化"
rpm -qa | grep -qE "^mysql-community-libs" && flag HIGH "mysql-community-libs(-compat) 替换了 mariadb-libs：用 yum swap 换回 mariadb-libs，否则删它会连带删 postfix"
[ -e /etc/ld.so.conf.d/mysql-x86_64.conf ] && flag MEDIUM "自定义 ld.so.conf.d/mysql-x86_64.conf（leapp 会告警）"
rpm -qa | grep -qE "^(webtatic|ius|nginx-release|mysql[0-9]*-community-release|remi-release|elrepo-release)" && flag MEDIUM "存在第三方 *-release 源包，7→8 前卸载，EL10 后按需重新加"
rpm -qa | grep -qE "^(python2-|python-)" && [ "$MAJOR" = 8 ] && flag INFO "EL8 仍有 python2 包；EL9 起没有 python2"

sec OPENSSH
rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE} vendor=%{VENDOR} sig=%{SIGPGP:pgpsig}\n' openssh-server 2>/dev/null
OSV=$(rpm -q --qf '%{VENDOR}' openssh-server 2>/dev/null)
case "$OSV" in *CentOS*|*AlmaLinux*|*"Red Hat"*) ;; *) flag BLOCKER "openssh-server 不是发行版官方包（vendor='$OSV'，常见于自编译 9.x）：先用 swap-openssh.sh 换回官方包，否则升级后 sshd 可能起不来=失联";; esac
[ -e /etc/rc.d/init.d/sshd ] && echo "sshd 使用 SysV 脚本 /etc/rc.d/init.d/sshd"
sshd -T 2>/dev/null | grep -E "^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|usepam|clientaliveinterval|clientalivecountmax|ciphers|macs) "
grep -qE "^\s*PermitRootLogin" /etc/ssh/sshd_config || { [ "$(id -u)" = 0 ] && flag HIGH "sshd_config 未显式写 PermitRootLogin：EL9+ 默认 prohibit-password，root 密码登录会失联。显式写上当前需要的值"; }
CACM=$(sshd -T 2>/dev/null | awk '/^clientalivecountmax/{print $2}')
SSHV=$(ssh -V 2>&1 | grep -oE "OpenSSH_[0-9]+.[0-9]+" | cut -d_ -f2)
[ "$CACM" = "0" ] && awk -v v="$SSHV" 'BEGIN{exit !(v+0 < 8.2)}' && flag INFO "ClientAliveCountMax 0：OpenSSH<8.2 下空闲会话会被断，远程脚本要开 keepalive，长任务用 systemd-run"
grep -hs "ssh-dss" /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys >/dev/null && flag BLOCKER "authorized_keys 含 ssh-dss (DSA) 公钥：EL9+ 不再支持，先换 ed25519/rsa 密钥"

sec SERVICES
echo "--- running:"; systemctl list-units --type=service --state=running --no-legend --no-pager | awk '{print $1}' | tr '\n' ' '; echo
echo "--- enabled:"; systemctl list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | tr '\n' ' '; echo
echo "--- failed:"; systemctl --failed --no-legend --no-pager
echo "--- SysV init scripts:"; ls /etc/rc.d/init.d/ 2>/dev/null | grep -vE "^(functions|README|netconsole|network)$"
echo "--- rc.local:"; RCL=$(grep -vE "^\s*#|^\s*$|touch /var/lock/subsys/local" /etc/rc.d/rc.local 2>/dev/null); echo "$RCL"
[ -n "$RCL" ] && flag MEDIUM "rc.local 里启动了东西（$(echo "$RCL" | head -3 | tr '\n' ';')）：升级后容易失效，改成 systemd unit"
echo "--- listening:"; ss -tulnp 2>/dev/null | awk 'NR>1{print $1, $5, $7}' | sort -u
systemctl is-active ntpd >/dev/null 2>&1 && flag INFO "ntpd 会被 leapp 迁移为 chronyd（自动）"

sec NETWORK
ip -br addr 2>/dev/null || ip addr; ip route; grep -v "^#" /etc/resolv.conf
echo "NetworkManager=$(systemctl is-active NetworkManager 2>/dev/null) network.service=$(systemctl is-active network 2>/dev/null)"
ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null
ls /etc/sysconfig/network-scripts/ifcfg-* >/dev/null 2>&1 && flag INFO "ifcfg 网络配置：9→10 前必须 nmcli connection migrate 转 keyfile（leapp 阻断项）"
[ "$(systemctl is-active NetworkManager 2>/dev/null)" != "active" ] && flag HIGH "NetworkManager 未运行（用的 network.service）：EL8+ 以 NM 为准，升级前先切到 NM 并验证网络"
grep -rqs "^dhcp *= *dhclient" /etc/NetworkManager/ /usr/lib/NetworkManager/conf.d/ && flag HIGH "NetworkManager 配了 dhcp=dhclient（注意 /usr/lib 下也可能有不属于任何包的残留文件）：EL10 没有 dhclient，是 9→10 阻断项；hop.sh answer 会处理"
for f in /etc/sysconfig/network-scripts/ifcfg-*; do [ -e "$f" ] || continue; case "$f" in *ifcfg-lo) continue;; esac; grep -q "^TYPE=" "$f" || flag MEDIUM "$(basename "$f") 没有 TYPE=：8→9 时 leapp 会报 unsupported device types（hop.sh answer 会用 nmcli connection migrate 处理）"; done
systemctl is-enabled iptables >/dev/null 2>&1 && flag INFO "iptables.service 已启用：EL9 起包名是 iptables-nft-services，8→9 会删除旧包；先看 /etc/sysconfig/iptables 里有没有真实规则"
echo "--- VPN / 隧道 / 访问路径:"
VPN=$(ps -eo comm,args 2>/dev/null | grep -iE "netbird|wireguard|wg-quick|openvpn|tailscale|zerotier|frpc|frps|strongswan|charon|softether|nps|npc" | grep -v grep)
ip -br link 2>/dev/null | grep -iE "wg|wt0|tun|tap|zt" ; echo "$VPN" | cut -c1-150
[ -n "$VPN" ] && flag BLOCKER "本机运行 VPN/隧道（$(echo "$VPN" | awk '{print $1}' | sort -u | tr '\n' ' ')）：先确认你是不是靠它连进来的！重启前绝不能 docker stop 它；准备好控制台 VNC/串口"

sec DOCKER/CONTAINERS
if has docker; then
  docker version --format 'server={{.Server.Version}} api={{.Server.APIVersion}}' 2>/dev/null
  docker info 2>/dev/null | grep -E "Storage Driver|Cgroup Driver|Cgroup Version|Docker Root Dir|Logging Driver"
  cat /etc/docker/daemon.json 2>/dev/null
  echo "--- containers (name | image | state | restart | network | compose dir):"
  for c in $(docker ps -aq 2>/dev/null); do
    docker inspect -f '{{.Name}} | {{.Config.Image}} | {{.State.Status}} | {{.HostConfig.RestartPolicy.Name}} | {{.HostConfig.NetworkMode}} | {{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null
  done
  docker system df 2>/dev/null
  NOAUTO=$(for c in $(docker ps -q); do docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $c; done | awk '$2=="no"||$2==""{print $1}' | tr '\n' ' ')
  [ -n "$NOAUTO" ] && flag HIGH "运行中但 restart=no 的容器（重启后不会自启）：$NOAUTO"
  UNL=$(for c in $(docker ps -q); do docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $c; done | awk '$2=="unless-stopped"{print $1}' | tr '\n' ' ')
  [ -n "$UNL" ] && flag HIGH "restart=unless-stopped 的容器：$UNL —— 重启前不要 docker stop 它们（手动停过就不会自启）"
  DV=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1); [ -n "$DV" ] && [ "$DV" -lt 20 ] 2>/dev/null && flag MEDIUM "Docker $DV.x 太老：leapp 会用 docker-ce 厂商源一起升级到新版（需要能访问 docker-ce 镜像源）"
  CV=$(docker-compose version --short 2>/dev/null); case "$CV" in 1.*) flag HIGH "docker-compose v1 ($CV)：Docker≥25 下报 KeyError 'ContainerConfig' 并会把容器改名成 <id>_name，升级后换成 compose v2 包装脚本";; esac
  CG1=$(docker ps -a --format '{{.Image}}' | grep -iE "yearning|tidb|openjdk:8|java:8|jdk8|elasticsearch:[56]\.|mysql:5\.[0-6]" | sort -u | tr '\n' ' ')
  [ -n "$CG1" ] && flag MEDIUM "可能依赖 cgroup v1 的镜像：$CG1（EL9 默认、EL10 只有 cgroup v2；见 app-compat.md 的 cgroup v1 shim）"
else echo "docker: not installed"; fi
has podman && podman ps -a 2>/dev/null

sec KUBERNETES
for b in kubectl helm kubeadm kubelet crictl k9s kubeconfig kubeconf; do has $b && echo "$b: $(command -v $b) $($b version --client --short 2>/dev/null || $b version --short 2>/dev/null | head -1)"; done
ls -la /root/.kube/ 2>/dev/null; grep -rn "KUBECONFIG\|kubectl\|kubeconf" /root/.bashrc /root/.bash_profile /etc/profile.d/ 2>/dev/null
has kubectl && timeout 20 kubectl version 2>/dev/null | grep -i server
systemctl is-active kubelet >/dev/null 2>&1 && flag BLOCKER "本机是 Kubernetes 节点（kubelet 运行中）：这是集群级变更，不能单台随手升。按 references/kubernetes.md 规划（访问路径是否在集群里、控制面入口、etcd、NFS 存储位置、能否整体中断），用 k8s.sh backup/pin/stop/fix/pods；换新节点也是选项"
systemctl is-active kubelet >/dev/null 2>&1 && flag INFO "K8s 节点到 EL10 后只有 cgroup v2：pod 里 8u372 / 11.0.16 之前的老 JDK 认不出容器内存限制，会按宿主机内存算堆而 OOMKilled → 恢复后用 k8s.sh jvm-maxram"
[ "$MAJOR" -lt 10 ] && rpm -q kubectl >/dev/null 2>&1 && flag INFO "kubectl 是 rpm 安装（$(rpm -q kubectl)）：升级后换成与集群版本匹配的 pkgs.k8s.io 源"

sec RUNTIMES/DATABASES
has java && java -version 2>&1 | head -1; rpm -qa 'java-*-openjdk*' 2>/dev/null | head
rpm -qa 'java-*-openjdk*' | grep -qE "java-(1\.8\.0|11|17)-openjdk" && flag MEDIUM "宿主机 Java 8/11/17：EL10 只有 21/25，宿主机直接跑的 Java 程序要改用容器或自带 JDK"
has python2 && echo "python2: $(python2 -V 2>&1)"; has python3 && echo "python3: $(python3 -V 2>&1)"
grep -rls "python2\|/usr/bin/python " /etc/cron* /var/spool/cron 2>/dev/null | sed 's/^/cron uses python2: /'
PIPN=0
for d in /usr/lib/python2.7/site-packages /usr/lib64/python2.7/site-packages /usr/lib/python3.6/site-packages /usr/lib64/python3.6/site-packages /usr/lib/python3.9/site-packages /usr/lib64/python3.9/site-packages; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do [ -e "$f" ] || continue; rpm -qf "$f" >/dev/null 2>&1 || { echo "UNOWNED $f"; PIPN=$((PIPN+1)); }; done
done
[ "$PIPN" -gt 0 ] && flag BLOCKER "有 $PIPN 个 pip 装的、不属于任何 rpm 的 site-packages 文件：升级时和 rpm 文件冲突(cpio rename)会让升级在 initramfs 里半途失败！EL7 上运行 prep-el7.sh pipfix（EL8/9 上 hop.sh prep 会自动挪走）"
has php && php -v 2>/dev/null | head -1
for p in mysqld mariadbd postgres postmaster mongod redis-server elasticsearch; do pgrep -x $p >/dev/null 2>&1 && echo "DB process: $p ($(readlink /proc/$(pgrep -xo $p)/exe 2>/dev/null))"; done
rpm -qa | grep -qE "^(mariadb-server|postgresql-server|mysql-server)-" && flag BLOCKER "宿主机装了 rpm 版数据库服务（$(rpm -qa | grep -E '^(mariadb-server|postgresql-server|mysql-server)-' | tr '\n' ' ')）：每跳都会大版本升级，数据目录格式变化。先逻辑备份(mysqldump/pg_dumpall)，制定每跳 mysql_upgrade/pg_upgrade 方案"

sec CUSTOM BINARIES（运行中、非 rpm 安装的可执行文件及其 EL7 库依赖）
for pid in $(ls /proc | grep -E '^[0-9]+$'); do readlink /proc/$pid/exe 2>/dev/null; done | grep -v " (deleted)" | sort -u | while read -r exe; do
  [ -f "$exe" ] || continue
  rpm -qf "$exe" >/dev/null 2>&1 && continue
  case "$exe" in /var/lib/docker/*|/var/lib/containerd/*|/proc/*) continue;; esac
  libs=$(ldd "$exe" 2>/dev/null | grep -oE "(libssl\.so\.10|libcrypto\.so\.10|libssl\.so\.1\.0[^ ]*|libpcre\.so\.1|libpython2[^ ]*|libmysqlclient\.so\.18|libboost[^ ]*\.so\.1\.53[^ ]*|libicu[^ ]*\.so\.50|libffi\.so\.6|libreadline\.so\.6|libnsl\.so\.1|not found)" | sort -u | tr '\n' ' ')
  echo "$exe  ${libs:+[EL7-libs: $libs]}"
  [ -n "$libs" ] && echo "$exe|$libs" >> /tmp/.survey_custom_bins
done
if [ -s /tmp/.survey_custom_bins ]; then
  while IFS='|' read -r e l; do flag HIGH "自编译程序 $e 依赖 EL7 库（$l）：升级后会起不来。方案：静态编译（nginx-static-build.sh）或改用新系统官方包"; done < /tmp/.survey_custom_bins
  rm -f /tmp/.survey_custom_bins
fi
for n in $(pgrep -a nginx 2>/dev/null | grep master | grep -oE "/[^ ]*nginx( |$)" | sort -u); do
  [ -x "$n" ] || { echo "--- $n: 在容器里运行（宿主机无此文件），见 DOCKER 段"; continue; }
  echo "--- $n -V:"; $n -V 2>&1
  $n -T 2>/dev/null | grep -nE "^\s*ssl\s+on;" | head -3 | grep -q . && flag MEDIUM "nginx 配置用了 'ssl on;'：nginx ≥1.25.1 已删除，迁移到新版时改成 'listen 443 ssl;'"
  echo "--- server_name:"; $n -T 2>/dev/null | grep -E "^\s*server_name" | sort -u
done
pgrep -a httpd 2>/dev/null | head -2

sec CRON/USERS
for u in $(cut -d: -f1 /etc/passwd); do crontab -l -u "$u" 2>/dev/null | grep -vE "^\s*#|^\s*$" | sed "s/^/[$u] /"; done
ls /etc/cron.d/; awk -F: '$3>=1000 && $3<65000 {print "user:", $1, $7}' /etc/passwd

sec CLOUD AGENTS
for d in /usr/local/aegis /usr/local/share/aliyun-assist /usr/local/cloudmonitor /usr/local/uniagent /usr/local/hostguard /opt/oss/servicemgr/ICAgent /CloudResetPwdUpdateAgent /CloudResetPwdAgent/opt/aws /snap/amazon-ssm-agent /usr/bin/amazon-ssm-agent /opt/aws/amazon-cloudwatch-agent; do [ -e "$d" ] && echo "agent: $d"; done
echo "cloud-init: $(rpm -q cloud-init 2>/dev/null) status=$(cloud-init status 2>/dev/null)"
ls /usr/lib/python2.7/site-packages 2>/dev/null | grep -q "cloud_init.*egg" && flag MEDIUM "cloud-init 是 pip/egg 安装的 py2 版本：升级后会坏，安装新系统的 cloud-init 包或禁用（AWS 慎重，见 cloud-providers.md）"

sec MAIL/MISC
has postconf && postconf -n 2>/dev/null | grep -E "hash:|btree:" && flag INFO "postfix 用了 hash:/btree: 表：EL10 无 libdb，升级后改 lmdb: 并 newaliases/postmap"
getenforce 2>/dev/null
lsmod | grep -E "^(floppy|pata_acpi|btrfs|nft_compat|ip_set) " | awk '{print "loaded module:", $1}'
lsmod | grep -qE "^(floppy|pata_acpi) " && flag HIGH "加载了 floppy/pata_acpi（7→8 阻断项）：rmmod 并加入 /etc/modprobe.d 黑名单"

echo
echo "################ RISK FLAGS ################"
if [ -z "$FLAGS" ]; then echo "(none)"; else
  for lv in BLOCKER HIGH MEDIUM INFO; do printf "%s" "$FLAGS" | grep "^\[$lv\]"; done
fi
echo "############################################"
