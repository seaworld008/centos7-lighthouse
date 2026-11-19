#!/bin/bash
# post-audit.sh - 升级完成后（或任意一跳之后）的只读体检：找出 leapp/新系统留下的"小问题"，末尾输出分级 FLAGS
#   bash post-audit.sh              # 完整检查（含 dnf check-update，需要能访问源）
#   POST_AUDIT_OFFLINE=1 bash post-audit.sh   # 不访问网络
# 只读：不修改系统。能自动修的项由 hop.sh tidy 处理，其余按 references/pitfalls.md 第 6 节人工处理。
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
T=$(mktemp -d /tmp/post-audit.XXXXXX); trap 'rm -rf "$T"' EXIT
has() { command -v "$1" >/dev/null 2>&1; }
flag() { echo "[$1] $2" >> "$T/flags"; }   # 级别: HIGH / MEDIUM / INFO（在子 shell 里调用也有效）
: > "$T/flags"
[ -f /etc/os-release ] && . /etc/os-release
echo "===== OS: ${PRETTY_NAME:-?} kernel=$(uname -r)"
has rpm || { echo "非 rpm 系统，跳过"; exit 0; }
MAJ=$(rpm -E %rhel 2>/dev/null); case "$MAJ" in ''|*[!0-9]*) MAJ=0;; esac
UP=no; { [ -d /var/log/leapp ] || ls /etc/*.leapp-bak-* >/dev/null 2>&1; } && UP=yes
echo "leapp_upgraded=$UP el=$MAJ"

echo "===== RPMNEW / LEAPP MARKERS"
find /etc -xdev \( -name '*.rpmnew' -o -name '*.rpmsave' \) -not -path '*/disabled-for-upgrade/*' 2>/dev/null | sort > "$T/rpmnew"
sed 's/^/  /' "$T/rpmnew"
c=$(grep -c . "$T/rpmnew"); [ "$c" -gt 0 ] && flag INFO "$c 个 .rpmnew/.rpmsave 待比对: $(xargs -n1 basename < "$T/rpmnew" | tr '\n' ' ' | cut -c1-300)"
grep -rIl --exclude='*.rpmnew' --exclude='*.rpmsave' --exclude='*leapp-bak*' -e 'content added by Leapp' /etc 2>/dev/null | head -20 > "$T/lm"
sed 's/^/  Leapp 追加内容: /' "$T/lm"
if [ -f /etc/virc ] && grep -q 'content added by Leapp' /etc/virc && grep -qE '^[[:space:]]*let ' /etc/virc; then
  flag HIGH "/etc/virc 有 Leapp 追加的 let/filetype 行：vim-minimal 的 vi 每次启动报 E319（crontab -e、visudo 受影响）→ hop.sh tidy"
fi
vierr() { TERM=xterm timeout 8 script -qc "$1 -c 'qa!' $T/vitest" /dev/null </dev/null 2>&1 | tr -d '\r' | grep -aoE 'E[0-9]{2,4}:' | sort | uniq -c | tr '\n' ' '; }
if has script; then
  for e in /usr/bin/vi /usr/bin/vim; do [ -x "$e" ] || continue; o=$(vierr "$e"); echo "  $e errors: ${o:-none}"; [ -n "$o" ] && flag HIGH "$e 启动报错 $o"; done
fi

echo "===== LOGIN SHELL"
o=$(timeout 15 bash -lic 'exit' 2>&1 </dev/null | grep -vE 'no job control|cannot set terminal process group|^[[:space:]]*$|^logout' | head -8)
echo "${o:-  ok}"; [ -n "$o" ] && flag HIGH "root 登录 shell 报错: $(echo "$o" | head -3 | tr '\n' ' ' | cut -c1-300)"

echo "===== PACKAGES"
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | grep -v '^gpg-pubkey' | grep -E '\.el[0-9]+' | grep -vE "\.el${MAJ}([._]|$)" | sort > "$T/old"
c=$(grep -c . "$T/old"); echo "  旧版本(非 el$MAJ)包: $c"; head -30 "$T/old" | sed 's/^/  /'
[ "$c" -gt 0 ] && flag INFO "$c 个旧版本(非 el$MAJ)包: $(head -10 "$T/old" | tr '\n' ' ')"
lp=$(rpm -qa 2>/dev/null | grep -E '^(leapp|python[23]?-leapp|snactor|elevate-release|leapp-upgrade|leapp-data|leapp-deps|leapp-repository|kernel-workaround)' | tr '\n' ' ')
ld=""; for p in /root/tmp_leapp_py3 /var/lib/leapp/el8userspace /var/lib/leapp/el9userspace /var/lib/leapp/el10userspace /var/lib/leapp/scratch /etc/yum.repos.d/ELevate.repo /etc/systemd/system/leapp_resume.service /boot/vmlinuz-upgrade.x86_64 /boot/initramfs-upgrade.x86_64.img; do [ -e "$p" ] && ld="$ld $p($(du -sh "$p" 2>/dev/null | cut -f1))"; done
echo "  leapp 残留包: ${lp:-无}"; echo "  leapp 残留路径: ${ld:-无}"
[ -n "$lp$ld" ] && flag MEDIUM "leapp 残留（升级完成后应清理；回退到旧版本的机器也要清）: $lp $ld"
if has dnf; then
  o=$(timeout 180 dnf -q check 2>&1 | head -15); [ -n "$o" ] && { echo "$o" | sed 's/^/  /'; flag HIGH "dnf check: $(echo "$o" | head -3 | tr '\n' ' ' | cut -c1-300)"; }
  if [ "${POST_AUDIT_OFFLINE:-0}" != 1 ]; then
    timeout 240 dnf -q check-update > "$T/cu" 2> "$T/cue"; rc=$?
    n=$(grep -cE '^[A-Za-z0-9_.+-]+\.(x86_64|noarch|i686)[[:space:]]' "$T/cu"); echo "  dnf check-update rc=$rc 可更新=$n"
    { [ "$rc" = 1 ] || grep -qiE 'error|failed' "$T/cue"; } && flag MEDIUM "dnf 源报错(rc=$rc): $(grep -iE 'error|fail' "$T/cue" | sort -u | head -3 | tr '\n' ' ' | cut -c1-300)"
    [ "$n" -gt 0 ] && flag INFO "$n 个包可更新"
  fi
fi
for f in /etc/yum.repos.d/*.repo; do
  [ -e "$f" ] || continue
  awk -v M="$MAJ" 'BEGIN{e=1} /^\[/{if(s&&e&&bad)print FILENAME" "s; s=$0; e=1; bad=0} /^enabled *= *0/{e=0}
    /^(baseurl|mirrorlist|metalink) *=/{for(v=5;v<M;v++){if($0 ~ ("(/|el|centos|rhel)" v "(/|-|\\.|$|Server)") || $0 ~ ("releasever=" v)) bad=1}}
    END{if(s&&e&&bad)print FILENAME" "s}' "$f"
done > "$T/repo"
sed 's/^/  旧版本源: /' "$T/repo"
[ -s "$T/repo" ] && flag MEDIUM "启用的源写死了旧版本号（如 docker-ce 的 centos/7）: $(tr '\n' ' ' < "$T/repo" | cut -c1-300)"

echo "===== KERNEL / BOOT"
dk=$(grubby --default-kernel 2>/dev/null); echo "  running=$(uname -r) default=${dk:-?}"
uname -r | grep -q "el$MAJ" || flag HIGH "运行内核 $(uname -r) 不是 el$MAJ"
[ -n "$dk" ] && ! echo "$dk" | grep -q "el$MAJ" && flag HIGH "默认启动内核不是 el$MAJ: $dk"
for e in /boot/loader/entries/*.conf; do [ -e "$e" ] || continue; k=$(awk '/^linux/{print $2}' "$e"); [ -n "$k" ] && [ ! -e "/boot${k#/boot}" ] && [ ! -e "$k" ] && flag MEDIUM "失效启动项 $e"; done
bu=$(df -P /boot 2>/dev/null | awk 'NR==2{print $5+0}'); [ -n "$bu" ] && [ "$bu" -ge 80 ] && flag MEDIUM "/boot 使用 $bu%"

echo "===== SYSTEMD"
systemctl --failed --no-legend --no-pager 2>/dev/null | sed 's/^/  /' | tee "$T/fu"
awk '{for(i=1;i<=NF;i++) if($i ~ /\.(service|mount|socket|timer|path|swap)$/){print $i; break}}' "$T/fu" > "$T/fun"
[ -s "$T/fun" ] && flag HIGH "failed units: $(tr '\n' ' ' < "$T/fun")"
act=$(systemctl list-units --state=activating --no-legend --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' '); [ -n "$act" ] && flag MEDIUM "长时间 activating（反复重启）: $act"
journalctl -b --no-pager -o cat 2>/dev/null | grep -E 'Unknown key|Unknown lvalue|is deprecated|Unknown section|has no ExecStart|Failed to parse|Couldn.t write|world-inaccessible|is obsolete|references a path below legacy' | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -15 | tee "$T/uw"
# 日志是本次开机以来的，unit 可能已经改好：只报文件里现在仍然写错段的键
journalctl -b --no-pager -o cat 2>/dev/null | grep -oE "^/[^:]+:[0-9]+: Unknown key '[A-Za-z]+' in section \[Install\]" | sort -u |
  while IFS=: read -r uf _ rest; do
    k=$(echo "$rest" | sed -E "s/.*key '([A-Za-z]+)'.*/\1/")
    [ -f "$uf" ] && awk -v k="$k" '/^\[/{s=$0} s=="[Install]" && $0 ~ "^"k"=" {f=1} END{exit !f}' "$uf" && echo "$uf: $k"
  done | head -3 | tr '\n' ';' > "$T/us"
[ -s "$T/us" ] && flag HIGH "unit 的键写在了 [Install] 段，被忽略: $(cat "$T/us")"
grep -lE '^[[:space:]]*fs\.may_detach_mounts' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | tr '\n' ' ' > "$T/md"
[ "$MAJ" -ge 8 ] && [ -s "$T/md" ] && flag MEDIUM "sysctl 里有 EL7 专用的 fs.may_detach_mounts（新内核没有这个键，开机 systemd-sysctl 报错）: $(cat "$T/md") → hop.sh tidy"
for l in /etc/systemd/system/*.wants/* /etc/systemd/system/*.requires/* /etc/rc.d/rc[0-6].d/*; do [ -L "$l" ] && [ ! -e "$l" ] && echo "$l"; done > "$T/dl"
sed 's/^/  失效链接: /' "$T/dl"
[ -s "$T/dl" ] && flag MEDIUM "$(grep -c . "$T/dl") 个失效的服务启用链接（服务已被删除）: $(head -6 "$T/dl" | xargs -n1 basename | tr '\n' ' ') → 已知旧服务由 hop.sh tidy 删除，其余人工确认"
if has logrotate && [ ! -x /etc/cron.daily/logrotate ] && ! systemctl is-enabled -q logrotate.timer 2>/dev/null; then
  flag HIGH "logrotate 没有被调度（没有 cron.daily/logrotate，logrotate.timer 未启用）：日志不再轮转，磁盘会被写满 → hop.sh tidy"
fi
if has logrotate; then
  o=$(timeout 60 logrotate -d /etc/logrotate.conf 2>&1 | grep -iE '^error' | sort -u | head -5); echo "  logrotate -d: ${o:-ok}"
  [ -n "$o" ] && flag MEDIUM "logrotate -d 报错（logrotate.d 里的 .bak 副本重复定义、日志父目录权限需要 su 等）: $(echo "$o" | head -3 | tr '\n' ';' | cut -c1-300)"
fi

echo "===== LIMITS / PAM / SUDO / SSH"
for f in /etc/security/limits.conf /etc/security/limits.d/*.conf; do
  [ -f "$f" ] || continue
  awk -v F="$f" '/^[[:space:]]*#/ || NF==0 {next}
    NF<4 || $2 !~ /^(soft|hard|-)$/ || $3 !~ /^(core|data|fsize|memlock|nofile|rss|stack|cpu|nproc|as|maxlogins|maxsyslogins|nonewprivs|priority|locks|sigpending|msgqueue|nice|rtprio|chroot)$/ || $4 !~ /^(-?[0-9]+|unlimited|infinity)$/ {print F ":" NR ": " $0}' "$f"
done > "$T/lim"
sed 's/^/  /' "$T/lim"
[ -s "$T/lim" ] && flag MEDIUM "limits 配置有写错的行（从未生效；pam_limits 每次登录/cron 都记错误）: $(head -3 "$T/lim" | tr '\n' ';' | cut -c1-300)"
if has sshd; then o=$(sshd -t 2>&1 | head -5); [ -n "$o" ] && flag HIGH "sshd -t: $(echo "$o" | tr '\n' ' ' | cut -c1-300)"; fi
if has visudo; then o=$(visudo -c 2>&1 | grep -v 'parsed OK'); [ -n "$o" ] && flag HIGH "visudo -c: $(echo "$o" | tr '\n' ' ' | cut -c1-300)"; fi
for f in /etc/pam.d/*; do
  [ -f "$f" ] || continue
  case "$f" in *.rpmnew|*.rpmsave|*-ac|*/fingerprint-auth|*/smartcard-auth) continue;; esac   # 指纹/智能卡栈默认就引用没装的模块，不算问题
  grep -vE '^[[:space:]]*#' "$f" | awk '{c=$2; if(c ~ /^\[/) c="complex"; for(i=2;i<=NF;i++) if($i ~ /pam_[A-Za-z0-9_]+\.so$/){n=split($i,p,"/"); print c" "p[n]; break}}' | sort -u |
    while read -r ctl m; do [ -e "/usr/lib64/security/$m" ] || [ -e "/lib64/security/$m" ] || echo "$ctl $f:$m"; done
done > "$T/pam"
grep -E '^(required|requisite|sufficient|complex) ' "$T/pam" | tr '\n' ' ' > "$T/pamh"; [ -s "$T/pamh" ] && flag HIGH "PAM 必需项引用了不存在的模块: $(cat "$T/pamh")"

echo "===== NETWORK / TIME"
systemctl is-active -q NetworkManager 2>/dev/null || flag HIGH "NetworkManager 未运行"
ifc=$(ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | grep -v 'ifcfg-lo$' | tr '\n' ' ')
[ "$MAJ" -ge 10 ] && [ -n "$ifc" ] && flag MEDIUM "EL10 上仍有 ifcfg 文件（NM 已不读）: $ifc"
ns=$(timedatectl show -p NTPSynchronized --value 2>/dev/null); [ -z "$ns" ] && timedatectl 2>/dev/null | grep -qiE '(NTP|System clock) synchronized: yes' && ns=yes
[ "$ns" = yes ] || flag MEDIUM "时间未同步（chronyd=$(systemctl is-active chronyd 2>/dev/null)）"
fv=$(findmnt --verify 2>&1 | grep -E '^[[:space:]]*\[E\]' | head -5); [ -n "$fv" ] && flag HIGH "findmnt --verify: $(echo "$fv" | tr '\n' ' ')"

echo "===== LOCAL BINARIES (ldd)"
# 不属于 rpm 的程序（云厂商 agent、/opt 下的商业软件）升级后可能缺旧库：libldap-2.4.so.2 → openldap-compat，libcrypt.so.1 → libxcrypt-compat
{ ls -d /usr/local/bin/* /usr/local/sbin/* 2>/dev/null
  for u in $(cat "$T/fun"); do systemctl show -p ExecStart --value "$u" 2>/dev/null | grep -oE 'path=[^ ;]+' | head -1 | cut -d= -f2; done
} | sort -u > "$T/bins"
while read -r f; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  head -c 4 "$f" 2>/dev/null | grep -q ELF || continue
  m=$(ldd "$f" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ',')
  [ -n "$m" ] && echo "$f: $m"
done < "$T/bins" > "$T/ldd"
sed 's/^/  /' "$T/ldd"
[ -s "$T/ldd" ] && flag HIGH "本地程序缺动态库（libldap/liblber-2.4 → 装 openldap-compat；libcrypt.so.1 → libxcrypt-compat）: $(head -4 "$T/ldd" | tr '\n' ';')"

echo "===== CRON"
systemctl is-active -q crond 2>/dev/null || flag HIGH "crond 未运行"
for mf in /var/spool/mail/root /var/mail/root; do
  [ -s "$mf" ] || continue
  tail -c 400000 "$mf" | grep -aE 'command not found|No such file|Permission denied|error while loading' | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -6 > "$T/mail"
  sed 's/^/  mail: /' "$T/mail"; [ -s "$T/mail" ] && flag INFO "root 邮件里有定时任务报错（可能是旧记录，看邮件日期）: $(head -2 "$T/mail" | tr -s ' ' | tr '\n' ';' | cut -c1-300)"
  break
done
o=$(journalctl -u crond --since '-30min' --no-pager -o cat 2>/dev/null | grep -iE 'error|fail|PAM|bad|ORPHAN|denied' | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -5)
[ -n "$o" ] && { echo "$o" | sed 's/^/  crond: /'; flag MEDIUM "crond 日志报错（最近 30 分钟）: $(echo "$o" | head -2 | tr -s ' ' | tr '\n' ';' | cut -c1-300)"; }

echo "################ POST-AUDIT FLAGS"
for L in HIGH MEDIUM INFO; do grep "^\[$L\]" "$T/flags"; done
echo "== HIGH=$(grep -c '^\[HIGH\]' "$T/flags") MEDIUM=$(grep -c '^\[MEDIUM\]' "$T/flags") INFO=$(grep -c '^\[INFO\]' "$T/flags")"
exit 0
