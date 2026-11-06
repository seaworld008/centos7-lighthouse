# 救援手册

## A. 重启后 SSH 一直不回来

1. 先确认是不是**访问路径**断了而不是机器挂了：本机 VPN 客户端（如 `netbird status -d`）看路由节点状态；云控制台看实例"运行中"、CPU 是否在动（升级进行中 CPU 会高）。
2. leapp 升级阶段（initramfs 里装包）正常需要 15~40 分钟，期间 SSH 不通是正常的。打开控制台 VNC/串口看进度。
3. 看到登录提示符 = 已进入新系统，只是网络/sshd/VPN 没起来：
   - 需要密码登录时请用户自己在控制台登录。
   - VPN 容器没起来：`docker start <vpn容器>`；sshd 没起来：`systemctl status sshd`、`sshd -t`。

## B. ★ 卡在 initramfs 紧急模式（"Entering emergency mode"，`upgrade.service failed`）

这个 shell 是 root，无需密码。工具很少（没有 head/tail/cut/clear），用 `grep -m N -o` 代替。

```sh
systemctl --failed --no-pager
journalctl -u upgrade.service -n 38 --no-pager -o cat          # 看 leapp 汇总
mount -o ro /dev/vda1 /sysroot                                  # 系统盘设备名按实际（vda1/nvme0n1p1/sda1）
cat /sysroot/etc/redhat-release                                 # 已经是新版本 → 事务大部分已执行
grep -cE 'install failed|erase failed|scriptlet failed' /sysroot/var/log/leapp/leapp-upgrade.log
grep -E 'install failed|erase failed|scriptlet failed|Verifying.*/' /sysroot/var/log/leapp/leapp-upgrade.log | grep -m 12 -o 'transaction: .\{0,140\}'
grep -E 'dnf_upgrade_transaction: (Error|error|warning)' /sysroot/var/log/leapp/leapp-upgrade.log | grep -m 25 -o 'transaction: .\{0,160\}'
ls /sysroot/boot | grep -E 'vmlinuz|initramfs'; grep saved_entry /sysroot/boot/grub2/grubenv
```

判断：
- **只有少数包失败、Verifying 到 N/N、默认启动项是新内核且 initramfs 存在** → 可以直接启动进新系统，再手工补完 leapp 没跑的收尾（下面 C）。
- **大量失败 / 新内核或 initramfs 缺失 / redhat-release 还是旧版** → 不要硬启动，回滚快照是最稳的；或在救援环境里排查。

启动前顺手修好会导致失联的东西（`mount -o remount,rw /sysroot`）：
- 容器被手动停过的：`sed -i 's/"HasBeenManuallyStopped":true/"HasBeenManuallyStopped":false/' /sysroot/var/lib/docker/containers/*/config.v2.json`
- 检查 PAM 是否还引用已删模块：`grep -l pkcs11 /sysroot/etc/pam.d/*`（只在 smartcard-auth 里无影响）

然后：`sync; umount /sysroot; systemctl reboot`

## C. "半升级"状态的收尾（leapp 后续阶段没跑）

进入新系统后：
1. 失败的那个包：先挪走冲突文件（通常是 pip 装的目录），再 `dnf install <包>`；用不上的（如 py2 包）直接忽略。
2. `hop.sh post <MIRROR>` 会因为失败标记 `/root/tmp_leapp_py3/.leapp_upgrade_failed` 停下：确认第 1 步处理完后删除该标记再执行。它会删旧内核/leapp/残留源、修 repo、dnf upgrade。
3. leapp 收尾里需要手工补的：`dnf -y upgrade --nobest`；cloud-init（禁用或重装）；SELinux 若是 enforcing 需要 `touch /.autorelabel` 再重启（disabled 则无需）。
4. `verify.sh <BACKUP_DIR>` 对比基线。
5. 进入下一跳前一定重新 `hop.sh prep`（会再跑 pipfix）。

## D. 换 openssh 后连不上

- swap-openssh.sh 失败会自动用旧 sshd 兜底；检查 `/root/os-upgrade-kit/ossh-swap/swap.log`。
- 控制台登录后：`/usr/sbin/sshd -t` 看配置错误；`systemctl status sshd`；必要时 `/root/os-upgrade-kit/ossh-swap/old-bin/sshd -f /etc/ssh/sshd_config`（9.x 旧版本需加 `-o SshdSessionPath=/root/os-upgrade-kit/ossh-swap/old-bin/sshd-session`）。

## E. 回滚

快照回滚是唯一完整的回滚。回滚前告诉用户：快照之后产生的业务数据（数据库写入、上传文件）会丢失，数据盘是否一起回滚由用户决定。
