# 应用兼容处理（EL7 → EL10）

## 目录
- nginx（自编译 → 官方包）
- Docker / compose / cgroup v2
- Java
- Jenkins / CI 构建机
- Node.js 构建工具链（多版本）
- GitLab（omnibus 容器）
- Python
- PHP
- 宿主机数据库
- postfix
- 网络（ifcfg → NetworkManager keyfile）
- SSH
- kubectl / helm / kubeconfig
- SysV init 与 rc.local
- TLS / 加密策略
- 其它

---

## nginx（自编译 → 官方包）

1. **过渡**：EL7 上用 `nginx-static-build.sh <nginx路径> --install` 同版本静态重编，三跳期间都能跑。
2. **最终**：`finalize.sh nginx-repo` 装 nginx.org stable，然后迁移配置：
   - 主配置写 `/etc/nginx/nginx.conf`，站点拆到 `/etc/nginx/conf.d/<域名>.conf`，证书放 `/etc/nginx/ssl/`（key 600）
   - 旧配置里的相对路径（`root html/xxx`、`cert/xxx`）全部改绝对路径；**网站目录可以不动**（先 grep 备份/清理脚本是否引用旧路径）
   - `ssl on;` 已在 1.25.1 删除 → `listen 443 ssl;`
   - 公共 TLS 参数提到 http 块：`ssl_protocols TLSv1.2 TLSv1.3;`（EL9+ 默认加密策略本来就禁 TLS1.0/1.1；若有老客户端要连，先问用户）
   - **`add_header` 继承规则**：server/location 里一旦写了 add_header，上层的全部不继承。原样保留原结构，行为才一致。
   - 旧配置里第一个 443 server 是隐式默认站点；下线它时加一个显式 `default_server` 返回和以前一致的结果（避免 ELB 健康检查/未知域名行为变化）。80 端口同理。
   - 去掉已下线组件的 location（如 fastcgi_pass 到已删 php-fpm）
   - 日志改到 /var/log/nginx（包自带 logrotate）
3. 切换：`nginx -t` 通过后停旧进程 → 删掉旧的自定义 unit / rc.local 行 → `systemctl enable --now nginx`；逐个域名用 `curl -sk --resolve 域名:443:127.0.0.1` 对比基线；`openssl s_client -tls1_1/-tls1_2/-tls1_3` 验证协议。

## Docker / compose / cgroup v2

- leapp 通过 vendors.d/docker-ce 把 docker-ce 一路升上去（19.03 → 26 → 29），数据目录和容器保留。前提：docker-ce 厂商源镜像可达且关掉 nightly/test。
- **重启前**：只停 `restart=always` 的有状态容器；`unless-stopped`/`no` 的不手动停（交给 docker.service 关机时优雅停止）。用 `hop.sh reboot`。
- **已经误停了**：离线（initramfs 或救援）编辑 `/var/lib/docker/containers/*/config.v2.json`，把 `"HasBeenManuallyStopped":true` 改 false，开机即自启（实测有效）。
- **docker-compose v1**：Docker ≥25 下 `KeyError: 'ContainerConfig'`，且会把旧容器改名为 `<id>_<name>`。用 `docker compose`；`finalize.sh compose-wrapper`。`version:` 字段告警可忽略。
- **cgroup v2**（EL9 默认，EL10 只有 v2）：
  - 读取 `/sys/fs/cgroup/memory/memory.limit_in_bytes` 的老程序会崩（实测 Yearning 3.0.9 / TiDB parser 的 `FATAL ... no such file`）。
  - 兼容 shim：在 compose 里给该服务挂 `./cgroupv1-shim:/sys/fs/cgroup:ro`，shim 目录里放 `memory/memory.limit_in_bytes`（9223372036854771712）和 `memory/memory.usage_in_bytes`（0）。`finalize.sh cgroupv1-shim <目录>` 生成文件。长期方案是升级应用版本。
  - JDK 8u372 之前的容器不识别 cgroup v2 内存限制（会按宿主机内存算堆大小）；显式写了 -Xmx 的不受影响。
- Docker 19.03 不支持 cgroup v2；必须随 leapp 升级到新版。
- **Harbor**：开机时 core/registry/nginx 等容器会因为 syslog 日志驱动连不上 harbor-log（127.0.0.1:1514）而 exited，Docker 不会重试。加一个 oneshot unit（After=docker.service）：循环等 1514 可用，然后 `docker ps -aq --filter label=com.docker.compose.project=<项目> --filter status=exited | xargs -r docker start`。

## Java

- EL10 只提供 Java 21/25；宿主机上 Java 8/11/17 会被 leapp 删除。容器里的 JDK 不受影响。
- 宿主机直接跑 jar 的：改用容器，或自带 JDK（如 Temurin 8/17 tar 包放 /opt），在 unit 里写绝对路径。

## Jenkins / CI 构建机

实测：Jenkins 2.346.1（最后一个支持 Java 8 的 LTS）+ 自带 JDK 8u92（tar 包）在 EL8/9/10 上原样可用，367 个任务、133 个插件不用动。**OS 升级时不要顺便升级 Jenkins**（2.361+ 要 Java 11/17，插件要一起升），另起变更。
- **先看实际版本**：rpm 版本常常不代表运行版本（war 被手工替换过）：`unzip -p /usr/lib/jenkins/jenkins.war META-INF/MANIFEST.MF | grep Jenkins-Version`。
- **启动方式**：老 rpm 是 SysV 脚本（依赖 `/etc/init.d/functions`）。在 EL7 上就换成原生 unit，并且**环境变量与现在完全一致**——构建任务继承 Jenkins 的环境：先 `tr '\0' '\n' < /proc/<pid>/environ` 记下 PATH/LANG/HOME/SHELL（实测 SysV 下 `PATH=/sbin:/usr/sbin:/bin:/usr/bin`，**不含 /usr/local/bin**），以及 `/proc/<pid>/limits` 的 nofile。要点：`Type=simple`、`User=root`（与原来一致）、去掉 `--daemon`、`KillMode=process`（构建里起的后台进程不随 Jenkins 重启被杀）、`SuccessExitStatus=143`。旧的"systemd 219 下监控 Jenkins PID"之类的看门狗 timer 换 unit 后用 `Restart=on-failure` 代替。
- **rpm 签名**：2.2xx 的 rpm 是 DSA/SHA1 签名，8→9 阻断。换完 unit 后 `rpm -e --justdb --noscripts --nodeps jenkins`（只删 rpm 记录，见 pitfalls.md 8→9）。
- **构建依赖的宿主机命令**：先统计任务 shell 里用到的命令（`<command>` 段的首个单词），逐个确认来源（rpm / /usr/local / tools 目录 / 远程 ssh 执行）。`/etc/profile` 里设置的 JAVA_HOME/MAVEN_HOME/node PATH 升级后保留（任务里 `source /etc/profile` 的照常可用）。
- **git**：1.8.3 → 2.43（EL8）→ 2.52（EL10），Jenkins git 插件 4.x 兼容；Jenkins 的 git 工具路径（`hudson.plugins.git.GitTool.xml`）若指向 SCL 的 `rh-git*`，SCL 会被删，先改成 `/usr/bin/git`。
- **rsync 推送**：rsyncd 在 EL8+ 由 `rsync-daemon` 包提供（leapp 实测会带上）；`/etc/rsyncd.conf`、secrets 文件保留。验证要从 `hosts allow` 里的部署机上做（本机 127.0.0.1 往往不在白名单）。
- **验证**：不想触发部署的话，把 workspace 复制出来（`rsync --exclude /.git --exclude /dist`——注意 `/dist` 前面的斜杠，否则会把 node_modules 里所有 dist 目录排除掉）按任务里的命令构建；Maven 用 `-o package` 不碰 ~/.m2。

## Node.js 构建工具链（多版本）

- **官方预编译的 Node 二进制向后兼容新 glibc**：实测 v11.11 / v13.12 / v15.2 / v16.14 / v16.20 / v17.9 / v18.20 / v20.19 在 AlmaLinux 10.2 上全部可用（含 vue-cli 2、cnpm、bower、yarn、pnpm 全局工具）。Jenkins NodeJS 插件装在 `$JENKINS_HOME/tools/jenkins.plugins.nodejs.tools.NodeJSInstallation/` 下的版本不用重装。
- **反而是 EL7 跑不了新 Node**：Node ≥18 官方二进制要 glibc 2.28，EL7 只有 2.17（`GLIBC_2.27 not found`）。升级后 Node 18/20/22 才真正能在宿主机上用。
- **node-sass（4.x）**：通常下载预编译 binding（`linux-x64-<abi>`），与 OS 无关；下载失败时回退 node-gyp 源码编译，老 node-gyp 需要 **python2，EL9 起没有**。给 npm 配置固定镜像兜底：`sass_binary_site=https://registry.npmmirror.com/-/binary/node-sass`（写进运行构建的用户的 `.npmrc`）。新项目用 dart-sass（`sass` 包）。
- **puppeteer/Chromium**：EL10 需要补 `nss atk at-spi2-atk cups-libs libdrm libxkbcommon libXcomposite libXdamage libXrandr mesa-libgbm pango alsa-lib gtk3`。
- 注意构建任务里的 `npm config set registry ...` 会改写全局 `~/.npmrc`；手工加的配置不要和它冲突。

## GitLab（omnibus 容器）

- 容器部署的 GitLab 与宿主机 OS 无关（实测 17.6.2 在 Docker 26 → 29、cgroup v1 → v2 下正常），数据卷、ssh host key（`config/ssh_host_*`）保留。
- **★ 必须设 `stop_grace_period: 5m`**：dockerd 重启（docker-ce 被 dnf 升级时）或关机时默认 10 秒就 SIGKILL，内置 PostgreSQL 留下锁文件，之后一直 502（见 pitfalls.md §6）。改完 `docker stop -t 300` 后 `docker compose up -d` 重建一次。
- 健康检查：`curl -s http://127.0.0.1/-/readiness?all=1`（容器内），`gitlab-ctl status` 全部 run；首次启动 2~5 分钟内 502 是正常的。
- 宿主机上的备份脚本（`gitlab-backup` 包装、保留策略）如果是 Python 写的，注意 shebang（见 pitfalls.md §7）。

## Python

- EL9 起无 python2；pip 装到系统 site-packages 的包是升级失败头号元凶（每跳前 pipfix）。
- 业务 Python 脚本：EL8=3.6，EL9=3.9，EL10=3.12。建议用 venv 或容器，不要往系统 site-packages 装东西。

## PHP

- webtatic（php72w 等）在 EL8+ 不存在。先问用户是否还用。
- 要用：remi 仓库（各版本按需），或 `php:<ver>-fpm` 容器监听 127.0.0.1:9000，把站点目录挂进去（扩展按 `php -m` 清单装）。
- 不用：卸载前列出依赖它的 nginx server（`fastcgi_pass`），告诉用户哪些站点会下线。

## 宿主机数据库

- rpm 版 mariadb/postgresql 每跳都会大版本升级：MariaDB 5.5→10.3→10.5→10.11 每跳后跑 `mysql_upgrade`/`mariadb-upgrade`；PostgreSQL 9.2→10→13→16 每跳都要 `pg_upgrade`（或最稳：升级前 `pg_dumpall`，升级后新建实例导入）。
- 数据量大/关键库：建议迁出到云数据库或新机器，不要原地连跳。
- 容器里的数据库不受影响，重启前优雅停止即可。
- 宿主机 tarball 版 MySQL 5.7（mysqld_safe + SysV）在 EL10 上能跑（要 EPEL 的 libxcrypt-compat、ncurses-compat-libs），但要补两件事（真实踩坑：每晚备份时内存超限被杀，停了 10 小时）：
  - unit 的 drop-in 加 `OOMPolicy=continue` + `Restart=on-failure`，内存上限用 `MemoryMax=`（见 pitfalls.md §7）
  - `[mysqld_safe]` 里加 `malloc-lib = /usr/lib64/libjemalloc.so.2`（`dnf install jemalloc`，EPEL）：glibc malloc 下 mysqld 的内存会随运行时间一直上涨
- 现成工具：`finalize.sh oom-policy`（上面第一条）；`scripts/mysql-backup.sh`（宿主机 + 容器实例统一备份：逐库 gzip、校验 `Dump completed`、导出账号、保留天数、`--check`、给 categraf 的 `--metrics`，用法见脚本开头）。
- 备份脚本：EL10 的 `/usr/bin/mysqldump` 是 8.4，忽略 `MYSQL_PWD`；`/etc/my.cnf` 里 `[mysqldump]` 段的 user/password 会覆盖环境变量。用 `--defaults-file=<600 临时文件>` 传账号，并用和服务端同大版本的 mysqldump（tarball 自带的，或 `docker exec` 容器里的）。每个文件检查 `-- Dump completed` 和管道退出码——`>/dev/null 2>&1` 的老 cron 脚本可能已经静默失败很久（真实案例：一个库里有大写表名、服务端 `lower_case_table_names=1`，全库备份每晚在这个库中止）。

## postfix

- EL10 无 libdb：`hash:`/`btree:` 表改 `lmdb:`，`newaliases`、`postmap` 重建。`finalize.sh postfix-lmdb`，最后用 `echo test | sendmail root` 看日志 `status=sent`。

## 网络（ifcfg → NetworkManager keyfile）

- 9→10 阻断项。`cp -a /etc/sysconfig/network-scripts <备份>` → `nmcli connection migrate` → `nmcli -f NAME,DEVICE,FILENAME c show` 确认 → `ip -br a; ip r` 不变。
- 云主机镜像常带 eth1~eth4 的 ifcfg（热插拔网卡用），一起迁移无害。
- Docker 的网桥连接在 /run 下，迁移不影响。
- `dhcp=dhclient` 的 NM 配置在 EL10 上必须去掉（EL10 无 dhclient）。

## SSH

- 自编译 openssh 先换回官方（swap-openssh.sh）。
- 显式写 `PermitRootLogin`（EL9 默认 prohibit-password）。
- EL9+ 默认加密策略禁用 SHA1 签名：很老的客户端（只支持 ssh-rsa SHA1）会连不上；DSA 密钥不再支持。
- `ClientAliveCountMax 0`：OpenSSH ≥ 8.2 表示禁用断线检测，<8.2 表示空闲即断。

## kubectl / helm / kubeconfig

- kubectl 与集群版本差不超过 ±1 minor。`finalize.sh kubectl auto` 读取集群版本并装对应 pkgs.k8s.io 源（国内走阿里云 kubernetes-new 镜像）。
- `~/.kube/config` 不动即可；`.bashrc` 里的 `source <(kubectl completion bash)` 需要 bash-completion 包。
- helm：`finalize.sh helm`（最新 v3，校验 sha256）。v4 有破坏性变化，未与用户确认不要升。
- 用户说"kubeconf 命令"，通常就是 kubectl + kubeconfig；先 grep 有没有同名 alias/脚本。

## SysV init 与 rc.local

- AlmaLinux 10.2 仍有 sysv-generator，SysV 脚本能启动；`finalize.sh sysv-units` 可生成原生 unit 备用。
- rc.local 里启动的业务（nginx、php-fpm、java…）改写为 systemd unit（Type、PIDFile、ExecStartPre 测试配置），`enable`，rc.local 里注释掉。
- 自编译 openssh 留下的 `/etc/rc.d/rc*.d/S55sshd` 链接要删。

## TLS / 加密策略

- EL9+：`DEFAULT` 策略禁 TLS1.0/1.1、SHA1 签名、<2048 位 RSA。影响两个方向：老客户端连本机；本机程序（curl、Java、python）连老服务器/老 MySQL。
- 临时兼容：`update-crypto-policies --set DEFAULT:SHA1` 或 `LEGACY`（需用户同意，记录在报告里，之后推动对端升级）。

## 其它

- ntpd → chronyd：leapp 自动迁移配置。
- denyhosts（py2）等老工具：EL9+ 失效，换 fail2ban。
- 云厂商 agent：见 cloud-providers.md。
