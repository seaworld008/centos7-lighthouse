#!/bin/bash
# verify.sh - 每跳升级后对比业务基线
# 用法: bash verify.sh <BACKUP_DIR 或 baseline.tsv 路径> [--wait 秒]
#   --wait N : 先最多等 N 秒，让容器 / Java 应用起来再对比（默认 90）
# 输出: FAIL（必须处理）/ WARN（需判断是否预期变化）/ OK，退出码 = FAIL 数量
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HERE=$(cd "$(dirname "$0")" && pwd)
BL=$1; [ -d "$BL" ] && BL="$BL/baseline.tsv"
[ -f "$BL" ] || { echo "用法: verify.sh <baseline.tsv|BACKUP_DIR>"; exit 99; }
WAIT=90; [ "$2" = "--wait" ] && WAIT=${3:-90}

# 等待：直到基线里 running 的容器都 running，且没有 restarting，或超时
t=0
while [ $t -lt "$WAIT" ]; do
  want=$(awk -F'\t' '$1=="ctr" && $3=="running"{print $2}' "$BL")
  ok=1
  for c in $want; do [ "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" = running ] || ok=0; done
  docker ps --format '{{.Status}}' 2>/dev/null | grep -qiE "restarting|starting" && ok=0
  [ $ok = 1 ] && [ $t -ge 30 ] && break
  sleep 10; t=$((t+10))
done

NOW=$(mktemp); bash "$HERE/state.sh" > "$NOW" 2>/dev/null
FAIL=0; WARNN=0
fail() { echo "FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { echo "WARN  $*"; WARNN=$((WARNN+1)); }

echo "== 系统: $(awk -F'\t' '$1=="os"{print $2}' "$BL")  →  $(awk -F'\t' '$1=="os"{print $2}' "$NOW")   kernel $(uname -r)"

# 服务：基线 active 的现在不 active
declare -A RENAMED=( [ntpd.service]=chronyd.service [network.service]=NetworkManager.service [iptables.service]=nftables.service )
awk -F'\t' '$1=="unit"{print $2}' "$BL" | while read -r u; do
  grep -qP "^unit\t${u//./\\.}$" "$NOW" && continue
  alt=${RENAMED[$u]}; [ -n "$alt" ] && grep -qP "^unit\t${alt//./\\.}$" "$NOW" && { echo "OK    $u → $alt（预期的替换）"; continue; }
  echo "WARN  服务 $u 升级前在运行，现在没有（systemctl status $u）"
done | tee /tmp/.v_units
WARNN=$((WARNN+$(grep -c ^WARN /tmp/.v_units)))

# 端口
awk -F'\t' '$1=="port"{print $2}' "$BL" | while read -r p; do
  grep -qP "^port\t$p$" "$NOW" && continue
  case "$p" in
    udp/*) echo "WARN  端口 $p 升级前在监听，现在没有（UDP 常因 dhcp/chrony 等实现变化而不同）";;
    *)     echo "FAIL  端口 $p 升级前在监听，现在没有";;
  esac
done | tee /tmp/.v_ports
FAIL=$((FAIL+$(grep -c ^FAIL /tmp/.v_ports))); WARNN=$((WARNN+$(grep -c ^WARN /tmp/.v_ports)))

# 容器
awk -F'\t' '$1=="ctr"{print $2"\t"$3}' "$BL" | while IFS=$'\t' read -r n s; do
  now=$(awk -F'\t' -v n="$n" '$1=="ctr" && $2==n{print $3}' "$NOW")
  if [ "$s" = running ] && [ "$now" != running ]; then echo "FAIL  容器 $n: 升级前 running，现在 ${now:-不存在}（docker logs --tail 50 $n）"; fi
done | tee /tmp/.v_ctr
FAIL=$((FAIL+$(grep -c ^FAIL /tmp/.v_ctr)))

# HTTP
awk -F'\t' '$1=="http"{print $2"\t"$3}' "$BL" | while IFS=$'\t' read -r url code; do
  now=$(awk -F'\t' -v u="$url" '$1=="http" && $2==u{print $3}' "$NOW")
  [ -z "$now" ] && now=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$url")
  [ "$code" = "$now" ] && continue
  if [ "$code" != 000 ] && [ "$now" = 000 ]; then echo "FAIL  $url: $code → $now（无响应）"
  else echo "WARN  $url: $code → $now"; fi
done | tee /tmp/.v_http
FAIL=$((FAIL+$(grep -c ^FAIL /tmp/.v_http))); WARNN=$((WARNN+$(grep -c ^WARN /tmp/.v_http)))

# kube
b=$(awk -F'\t' '$1=="kube"{print $3}' "$BL"); n=$(awk -F'\t' '$1=="kube"{print $3}' "$NOW")
[ -n "$b" ] && { [ "$b" = "$n" ] && echo "OK    kubectl get nodes: $n Ready" || { echo "FAIL  kubectl: 基线 $b 个 Ready 节点，现在 ${n:-命令失败}"; FAIL=$((FAIL+1)); }; }

echo "== systemctl --failed:"; systemctl --failed --no-legend --no-pager
echo "== 磁盘:"; df -h / /var /boot 2>/dev/null | awk 'NR==1||!seen[$0]++'
cp "$NOW" "$(dirname "$BL")/state-$(date +%Y%m%d-%H%M).tsv" 2>/dev/null
rm -f "$NOW" /tmp/.v_units /tmp/.v_ports /tmp/.v_ctr /tmp/.v_http
echo "== 结果: FAIL=$FAIL WARN=$WARNN"
exit $FAIL
