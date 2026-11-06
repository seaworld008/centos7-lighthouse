#!/bin/bash
# swap-openssh.sh - 把自编译/第三方 openssh 换回发行版官方包（保留 sshd_config、端口、主机密钥）
#
# 为什么：leapp 不会升级"非官方签名"的 openssh，EL7 自编译 rpm 留到 EL8+ 后依赖缺失/SysV 脚本失效 → sshd 起不来 = 失联。
# 安全措施：
#   1. 先用官方二进制 sshd -t 测试现有 sshd_config，不通过就不换
#   2. 备份原 sshd/sshd-session 二进制
#   3. 用 systemd-run 脱离当前 SSH 会话执行（换包时当前会话可能被杀）
#   4. 换完 3 秒内端口没起来 → 自动用备份的旧 sshd 拉起来兜底
# 用法: bash swap-openssh.sh        （执行后用一个新连接验证，再看 /root/os-upgrade-kit/ossh-swap/swap.log）
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
W=/root/os-upgrade-kit/ossh-swap; mkdir -p "$W"; cd "$W" || exit 1
rpm -q openssh-server >/dev/null 2>&1 || { echo "openssh-server 未安装（rpm），无需替换"; exit 0; }
V=$(rpm -q --qf '%{VENDOR}' openssh-server)
case "$V" in *CentOS*|*AlmaLinux*|*"Red Hat"*) echo "openssh-server 已是官方包（$V），无需替换"; exit 0;; esac
PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'); PORT=${PORT:-22}
echo "当前: $(rpm -q openssh-server) vendor='$V'  sshd 端口 $PORT"

rm -f ./*.rpm; rm -rf x
if command -v dnf >/dev/null; then dnf -q download openssh openssh-server openssh-clients 2>&1 | tail -2
else rpm -q yum-utils >/dev/null || yum -y install yum-utils >/dev/null; yumdownloader -q openssh openssh-server openssh-clients 2>&1 | tail -2; fi
# yumdownloader 默认取最高版本，自编译版本号更高时它可能取不到官方包 → 明确过滤官方签名
ls ./*.rpm >/dev/null 2>&1 || { echo "下载官方 openssh 失败，检查 yum 源"; exit 1; }
for r in ./*.rpm; do rpm -qp --qf '%{VENDOR}\n' "$r" | grep -qE "CentOS|AlmaLinux|Red Hat" || { echo "$r 不是官方包，退出"; exit 1; }; done
mkdir x && (cd x && for r in ../*.rpm; do rpm2cpio "$r" | cpio -idm 2>/dev/null; done)
x/usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>&1 | grep -v "UsePAM no" ; x/usr/sbin/sshd -t -f /etc/ssh/sshd_config >/dev/null 2>&1 \
  || { echo "!! 官方 sshd 不接受现有 sshd_config（上面是报错），先修配置再换"; exit 1; }
echo "官方 sshd 测试现有配置: OK"
mkdir -p old-bin; cp -a /usr/sbin/sshd old-bin/; cp -a /usr/libexec/openssh/sshd-session old-bin/ 2>/dev/null; cp -a /etc/ssh "$W/etc-ssh.bak"

cat > swap.sh <<EOF
#!/bin/bash
exec > $W/swap.log 2>&1; set -x
cd $W
rpm -Uvh --oldpackage --replacefiles --replacepkgs ./*.rpm
cp -a $W/etc-ssh.bak/sshd_config /etc/ssh/sshd_config
[ -e /etc/rc.d/init.d/sshd ] && rpm -qf /etc/rc.d/init.d/sshd >/dev/null 2>&1 || rm -f /etc/rc.d/init.d/sshd /etc/rc.d/rc*.d/[SK]*sshd
chmod 600 /etc/ssh/ssh_host_*_key; getent group ssh_keys >/dev/null && chgrp ssh_keys /etc/ssh/ssh_host_*_key
systemctl daemon-reload
/usr/sbin/sshd -t || echo CONFIG_FAIL
for p in \$(pgrep -f '^/usr/sbin/sshd'); do [ "\$(ps -o ppid= -p \$p | tr -d ' ')" = 1 ] && kill \$p; done
sleep 1; systemctl reset-failed sshd; systemctl enable sshd; systemctl start sshd; sleep 3
if ss -tlnp | grep -q ":$PORT .*sshd"; then echo SWAP_OK; else
  echo SWAP_FAIL_FALLBACK
  if [ -x $W/old-bin/sshd-session ]; then $W/old-bin/sshd -f /etc/ssh/sshd_config -o SshdSessionPath=$W/old-bin/sshd-session
  else $W/old-bin/sshd -f /etc/ssh/sshd_config; fi
fi
EOF
chmod +x swap.sh
systemd-run --unit="ossh-swap-$(date +%s)" "$W/swap.sh" >/dev/null && echo "已在后台执行替换。15 秒后用【新连接】验证，再看 $W/swap.log（应有 SWAP_OK）"
