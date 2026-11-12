#!/bin/bash
# rescue-grubenv.sh - 在"救援机"上把另一台机器的默认启动项改回旧内核（不需要登录救援机）
#
# 场景：升级重启后卡在 leapp 的升级 initramfs（例如华为云 c9 上 EL10 内核探测 ata_piix 挂死），
# 而 VNC 又抢不到 GRUB 菜单（强制重启后控制台重连太慢），leapp 又把升级项设成了持久默认项。
# 此时系统盘内容还没被改动，只要把 grubenv 的 saved_entry 改回旧内核即可原样启动。
#
# 用法（见 references/recovery.md F 节）：
#   1. 故障机关机，卸载系统盘
#   2. 在同一可用区创建/找一台救援机（按需计费即可），把本脚本作为"实例自定义数据(user data)"注入，
#      或者已有救援机时：bash rescue-grubenv.sh [超时分钟]
#   3. 把故障机的系统盘以"数据盘"挂到救援机；脚本发现带 *-upgrade.*.conf 启动项的分区后自动修改并卸载，
#      结果打印到 VNC 控制台：  OSUP: DONE ... saved_entry=...  /  OSUP: UMOUNTED ... SAFE TO DETACH
#   4. 从救援机卸载该盘，以"系统盘"挂回故障机，开机；删除救援机
#
# 环境变量：KEEP_PATTERN  保留的内核版本匹配（默认按目标系统的上一跳自动选：有 .el9 选 el9，否则 el8）
#           MOUNT_DIR     临时挂载点（默认 /mnt/osup-rescue）
TIMEOUT_MIN=${1:-120}
MNT=${MOUNT_DIR:-/mnt/osup-rescue}
LOG=/var/log/osup-rescue.log
say() { echo "OSUP: $*" | tee -a "$LOG"; for t in /dev/console /dev/tty1 /dev/ttyS0; do echo "OSUP: $*" > "$t" 2>/dev/null; done; }

ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null)
ROOTDISK=$(lsblk -npo PKNAME "$ROOTSRC" 2>/dev/null | head -1)
say "waiting for the disk to rescue (own root disk ${ROOTDISK:-unknown}), timeout ${TIMEOUT_MIN} min"
mkdir -p "$MNT"
end=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  for p in $(lsblk -lnpo NAME,TYPE | awk '$2=="part"||$2=="lvm"{print $1}'); do
    case "$p" in "$ROOTSRC") continue;; esac
    [ -n "$ROOTDISK" ] && case "$p" in "$ROOTDISK"*) continue;; esac
    # xfs 克隆盘与救援机 UUID 相同时需要 nouuid；ext4 不认 nouuid，失败后再普通挂载
    mount -o nouuid "$p" "$MNT" 2>/dev/null || mount "$p" "$MNT" 2>/dev/null || continue
    B=$MNT/boot; [ -d "$MNT/loader/entries" ] && B=$MNT          # 独立 /boot 分区
    if ls "$B"/loader/entries/*-upgrade.*.conf >/dev/null 2>&1; then
      pat=${KEEP_PATTERN:-}
      if [ -z "$pat" ]; then
        if ls "$B"/loader/entries/ | grep -v rescue | grep -q '\.el9'; then pat='\.el9'; else pat='\.el8'; fi
      fi
      E=$(ls "$B"/loader/entries/ | grep -v rescue | grep -v upgrade | grep "$pat" | sed 's/\.conf$//' | sort -V | tail -1)
      if [ -z "$E" ]; then say "FAIL $p: no kernel entry matching $pat"; umount "$MNT"; exit 1; fi
      cp -a "$B/grub2/grubenv" "$B/grub2/grubenv.osup-bak-$(date +%Y%m%d%H%M)"
      grub2-editenv "$B/grub2/grubenv" set "saved_entry=$E"
      say "DONE $p $(grub2-editenv "$B/grub2/grubenv" list | grep saved_entry)"
      sync; umount "$MNT" && say "UMOUNTED $p - SAFE TO DETACH"
      exit 0
    fi
    umount "$MNT"
  done
  sleep 5
done
say "TIMEOUT: no disk with an upgrade boot entry found"
exit 1
