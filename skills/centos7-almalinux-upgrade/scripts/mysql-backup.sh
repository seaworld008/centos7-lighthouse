#!/bin/bash
# mysql-backup.sh - MySQL/MariaDB 逻辑备份（宿主机实例 + 容器实例），每个库一个文件、逐个校验、可监控
# 来源：一次真实巡检——老的 cron 备份脚本 `>/dev/null 2>&1` 静默失败了几个月（全库备份每晚在一个坏库中止、
#       部分库从没备份过），宿主机 MySQL 在每晚备份时 OOM。用它替换各种 auto_backup_*.sh。
#
# 安装：install -m 755 mysql-backup.sh /usr/local/sbin/mysql-backup
#       每个实例一个配置 /etc/mysql-backup/<name>.conf（chmod 600，里面有密码），例如：
#         MODE=tcp                      # tcp：宿主机上的客户端连 HOST:PORT；docker：用容器里同版本的 mysqldump
#         HOST=127.0.0.1  PORT=3306
#         DUMP_DIR=/usr/local/mysql/bin # tcp 模式：mysql/mysqldump 所在目录，要和服务端同大版本（EL10 的 /usr/bin/mysqldump 是 8.4）
#         CONTAINER=mysql8              # docker 模式：容器名（容器内连 127.0.0.1:3306）
#         DB_USER=root
#         DB_PASS='...'
#         DEST=/data/backup-data/mysql-<name>
#         KEEP_DAYS=14  KEEP_MIN=3      # 成功的备份保留 KEEP_DAYS 天，且至少保留最近 KEEP_MIN 份
#         EXCLUDE_RE='^(information_schema|performance_schema|sys|mysql)$'   # 读不了的坏库也加在这里，并告诉用户
#       cron：0 2 * * * /usr/local/sbin/mysql-backup >/dev/null 2>&1      （日志在 /var/log/mysql-backup.log）
#       监控：categraf input.exec 的 commands 加 "/usr/local/sbin/mysql-backup --metrics"（data_format = "influx"）
#             → mysql_backup_ok / mysql_backup_age_hours / mysql_backup_size_mb，告警 ok==0 或 age_hours>26
#
# 用法：mysql-backup              依次备份所有实例（一次只备份一个，避免内存/IO 叠加）
#       mysql-backup <name>       只备份一个实例
#       mysql-backup --check      列出每个实例最近一次结果；有失败或超过 26 小时没有新备份时返回 1
#       mysql-backup --metrics    influx 格式的状态指标（给 categraf exec）
#
# 产物：$DEST/<YYYY-mm-dd_HHMM>/<db>.sql.gz（--databases，含建库语句、存储过程、事件、触发器）+ _grants.sql + MANIFEST
#       进行中的目录带 .partial，失败的改名 .FAILED；$DEST/LAST_STATUS 是最近一次结果
# 恢复：zcat <db>.sql.gz | mysql -uroot -p -h<host> -P<port>        （恢复到同名库）
#       恢复到别的库名：先用 sed 改掉开头的 CREATE DATABASE 和 USE 两行；账号：mysql -uroot -p < _grants.sql
set -uo pipefail
export LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF_DIR=${MYSQL_BACKUP_CONF_DIR:-/etc/mysql-backup}
LOG=${MYSQL_BACKUP_LOG:-/var/log/mysql-backup.log}
LOCK=${MYSQL_BACKUP_LOCK:-/run/mysql-backup.lock}
ZIP="gzip"; command -v pigz >/dev/null 2>&1 && ZIP="pigz -p 2"
UNZIP="gzip -dc"; command -v pigz >/dev/null 2>&1 && UNZIP="pigz -dc"

log() {
  local m; m="$(date '+%F %T') [${NAME:-main}] $*"
  echo "$m" >> "$LOG" 2>/dev/null; echo "$m"
  command -v logger >/dev/null 2>&1 && logger -t mysql-backup -- "$m"
  return 0
}

# 只给本次用的客户端配置，配合 --defaults-file：不读 /etc/my.cnf（里面 [mysqldump] 的 user/password 会覆盖别的来源），
# 密码只经过 600 临时文件或管道，不出现在命令行（8.4 客户端也不认 MYSQL_PWD）
client_cnf() {
  local p=${DB_PASS//\\/\\\\}; p=${p//\"/\\\"}
  if [ "$MODE" = docker ]; then
    printf '[client]\nuser=%s\npassword="%s"\nprotocol=tcp\nhost=127.0.0.1\nport=3306\n' "$DB_USER" "$p"
  else
    printf '[client]\nuser=%s\npassword="%s"\nprotocol=tcp\nhost=%s\nport=%s\n' "$DB_USER" "$p" "$HOST" "$PORT"
  fi
}
run_client() {   # run_client mysql|mysqldump args...
  local bin=$1; shift
  if [ "$MODE" = docker ]; then
    client_cnf | docker exec -i "$CONTAINER" sh -c 'f=$(mktemp); cat > "$f"; b=$1; shift; "$b" --defaults-file="$f" "$@"; rc=$?; rm -f "$f"; exit $rc' sh "$bin" "$@"
  else
    local f rc; f=$(mktemp); chmod 600 "$f"; client_cnf > "$f"
    "$DUMP_DIR/$bin" --defaults-file="$f" "$@"; rc=$?; rm -f "$f"; return $rc
  fi
}
sql() { run_client mysql -NB -e "$1"; }

load_conf() {
  MODE=tcp; CONTAINER=""; DUMP_DIR=/usr/bin; HOST=127.0.0.1; PORT=3306; DB_USER=root; DB_PASS=""
  DEST=""; KEEP_DAYS=14; KEEP_MIN=3; EXCLUDE_RE='^(information_schema|performance_schema|sys|mysql)$'
  NAME=$(basename "$1" .conf)
  # shellcheck disable=SC1090
  . "$1"
}
fail_status() { echo "FAIL $(date '+%F %T') $*" > "$DEST/LAST_STATUS"; log "FAIL $*"; }

backup_one() {
  load_conf "$1"
  [ -n "$DEST" ] || { log "配置缺少 DEST"; return 1; }
  mkdir -p "$DEST"
  local ver; ver=$(sql "SELECT VERSION()" 2>&1) || { fail_status "连接失败：$(echo "$ver" | tail -1)"; return 1; }
  local opts=(--single-transaction --quick --routines --events --triggers --hex-blob --max-allowed-packet=1G --default-character-set=utf8mb4)
  case "$ver" in
    *MariaDB*) ;;
    *) [ "$(sql 'SELECT @@gtid_mode' 2>/dev/null)" = ON ] && opts+=(--set-gtid-purged=OFF) ;;
  esac

  # 剩余空间至少是上一次成功备份的 2 倍
  local last; last=$(ls -1d "$DEST"/20??-??-??_???? 2>/dev/null | tail -1)
  if [ -n "$last" ]; then
    local need avail; need=$(( $(du -sk "$last" | cut -f1) * 2 )); avail=$(df -Pk "$DEST" | awk 'NR==2{print $4}')
    [ "$avail" -gt "$need" ] || { fail_status "磁盘空间不足：剩 ${avail}KB，需要 ${need}KB"; return 1; }
  fi

  local stamp dir; stamp=$(date +%F_%H%M); dir="$DEST/$stamp.partial"; mkdir -p "$dir"
  log "开始 server=$ver -> $dir"
  local t0 fail=0 n=0 db f t1 ok; t0=$(date +%s)
  local dbs; dbs=$(sql "SHOW DATABASES" | grep -vE "$EXCLUDE_RE")
  for db in $dbs; do
    n=$((n+1)); f="$dir/$db.sql.gz"; t1=$(date +%s)
    run_client mysqldump "${opts[@]}" --databases "$db" 2>"$dir/.err" | $ZIP > "$f"
    local rcs=("${PIPESTATUS[@]}")
    ok=0; $UNZIP "$f" 2>/dev/null | tail -c 200 | grep -q "Dump completed" && ok=1   # 中途失败的 dump 没有这一行
    if [ "${rcs[0]}" = 0 ] && [ "${rcs[1]}" = 0 ] && [ $ok = 1 ]; then
      echo "OK   $db $(du -h "$f" | cut -f1) $(( $(date +%s) - t1 ))s" >> "$dir/MANIFEST"
    else
      fail=$((fail+1)); echo "FAIL $db rc=${rcs[*]} completed=$ok $(head -c 300 "$dir/.err" | tr '\n' ' ')" >> "$dir/MANIFEST"
      log "FAIL $db rc=${rcs[*]} $(head -c 300 "$dir/.err" | tr '\n' ' ')"
    fi
  done
  rm -f "$dir/.err"

  # 账号和权限（不 dump mysql 系统库：8.0 不建议这样恢复，也不跨版本）；root 不导出，避免恢复时覆盖
  {
    echo "-- users & grants of $NAME ($ver) $(date '+%F %T')"
    sql "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','root') AND user<>''" | while read -r u; do
      sql "SHOW CREATE USER $u" 2>/dev/null | sed 's/$/;/'
      sql "SHOW GRANTS FOR $u" 2>/dev/null | sed 's/$/;/'
    done
  } > "$dir/_grants.sql" 2>/dev/null || true

  local secs size; secs=$(( $(date +%s) - t0 )); size=$(du -sh "$dir" | cut -f1)
  if [ $n -gt 0 ] && [ $fail = 0 ]; then
    mv "$dir" "$DEST/$stamp"
    echo "OK $(date '+%F %T') dbs=$n size=$size secs=$secs dir=$DEST/$stamp" > "$DEST/LAST_STATUS"
    log "完成 $n 个库，$size，${secs}s"
  else
    mv "$dir" "$DEST/$stamp.FAILED"
    fail_status "dbs=$n failed=$fail dir=$DEST/$stamp.FAILED（见 MANIFEST）"
  fi

  # 清理：成功的保留 KEEP_DAYS 天且至少 KEEP_MIN 份；失败/中断的目录保留 KEEP_DAYS 天
  ls -1d "$DEST"/20??-??-??_???? 2>/dev/null | head -n -"$KEEP_MIN" | while read -r d; do
    [ -n "$(find "$d" -maxdepth 0 -mtime +"$KEEP_DAYS")" ] && { rm -rf "$d"; log "删除过期备份 $d"; }
  done
  find "$DEST" -maxdepth 1 -type d \( -name '*.FAILED' -o -name '*.partial' \) -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null
  [ $fail = 0 ] && [ $n -gt 0 ]
}

status_of() {   # 输出：ok age_hours size_mb status_line
  local s="$DEST/LAST_STATUS" ok=0 age=-1 size=0 line="NONE" dir
  if [ -f "$s" ]; then
    line=$(cat "$s"); case "$line" in OK*) ok=1;; esac
    age=$(( ($(date +%s) - $(stat -c %Y "$s")) / 3600 ))
    dir=$(echo "$line" | grep -oE 'dir=[^ ]+' | cut -d= -f2)
    [ -n "$dir" ] && [ -d "$dir" ] && size=$(du -sm "$dir" | cut -f1)
  fi
  echo "$ok $age $size $line"
}

case "${1:-}" in
  --check)
    rc=0
    for c in "$CONF_DIR"/*.conf; do
      [ -e "$c" ] || continue
      load_conf "$c"; read -r ok age _ line <<< "$(status_of)"
      echo "$NAME: $line (${age}h ago)"
      { [ "$ok" = 1 ] && [ "$age" -le 26 ]; } || rc=1
    done
    exit $rc ;;
  --metrics)
    for c in "$CONF_DIR"/*.conf; do
      [ -e "$c" ] || continue
      load_conf "$c"; read -r ok age size _ <<< "$(status_of)"
      echo "mysql_backup,instance=$NAME ok=${ok}i,age_hours=${age}i,size_mb=${size}i"
    done
    exit 0 ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
esac

renice -n 10 $$ >/dev/null 2>&1; ionice -c2 -n7 -p $$ >/dev/null 2>&1   # 宿主机侧（压缩、tcp 模式的 mysqldump）低优先级
exec 9>"$LOCK"; flock -n 9 || { log "上一次备份还在运行，跳过"; exit 1; }
rc=0
if [ -n "${1:-}" ]; then
  [ -f "$CONF_DIR/$1.conf" ] || { echo "没有 $CONF_DIR/$1.conf"; exit 2; }
  backup_one "$CONF_DIR/$1.conf" || rc=1
else
  for c in "$CONF_DIR"/*.conf; do [ -e "$c" ] || continue; backup_one "$c" || rc=1; done
fi
exit $rc
