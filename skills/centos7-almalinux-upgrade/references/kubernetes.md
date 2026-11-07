# Kubernetes 节点原地升级（kubeadm 集群，K8s 版本保持不变）

> 来源：一次真实执行（阿里云测试环境，3 master + 3 worker，K8s 1.21.5 + Docker 19.03/dockershim + flannel v0.17 + kube-proxy ipvs + stacked etcd + NFS 存储类，CentOS 7.9 → AlmaLinux 10.2，约 6 小时）。见 field-reports/2026-11-07-aliyun-k8s-1.21-3m3w.md。

**能不能原地升**：能。但它不是"每台单独升"，而是"整个集群的一次变更"。动手前先回答下面几个问题，答不上来就先别动。

## 1. 开工前必须弄清楚的事
| 问题 | 怎么查 | 为什么重要 |
|---|---|---|
| 你是怎么连进这些机器的？VPN/路由节点是不是跑在这个集群的 pod 里？ | `netbird status -d` / 路由表；`kubectl get pods -A -o wide \| grep -i -E 'vpn\|netbird\|wireguard'` | 集群一停你就失联 |
| 控制面入口是什么？（LB、keepalived VIP、某台 master 上的 nginx） | `grep server: /etc/kubernetes/kubelet.conf` | 入口跑在某台 master 上时，那台不能和别的一起停 |
| etcd 是 stacked 还是外置？几个成员？ | `ls /etc/kubernetes/manifests/` | 同时停超过半数成员 = 集群不可写（允许全停时无所谓，起来会自动恢复） |
| PV 存储在哪？（NFS 服务端在集群某台机器上很常见） | `kubectl get sc,pv`；provisioner 的 `NFS_SERVER` | 存储所在节点要最先恢复 |
| 容器运行时 / cgroup 驱动 / CNI / kube-proxy 模式 | `kubectl get nodes -o wide`；`/var/lib/kubelet/config.yaml`；`kubectl -n kube-system get cm kube-proxy -o yaml` | 决定 EL10（只有 cgroup v2、Docker 29）能不能跑 |
| pod 能不能迁移？能不能全部中断？ | 问用户 | 决定是"滚动 drain"还是"整体停机一起升" |

## 2. 兼容性结论（已验证）
- **K8s 1.21 + dockershim + Docker 29.9.3 + cgroup v2（EL10）可以跑**：Docker 29 的最低 API 是 1.40，dockershim 客户端是 1.41；kubelet `cgroupDriver: systemd` 与 Docker 一致即可。
- EL10 内核有 ip_tables/ip_set/ip_vs/br_netfilter/vxlan/overlay 等模块；**flannel v0.17 镜像自带 iptables-wrapper**，在 EL10 上会自动选 nft；kube-proxy ipvs 正常。
- kubelet rpm 的依赖（conntrack、ebtables、socat、ethtool、iptables）在 EL10 都有提供者（iptables-nft 提供 ebtables/iptables），leapp 不会删 kubelet。
- 用金丝雀验证：先把一台 worker 升到 EL10，用 `nodeName` 固定的测试 pod 验证 DNS、Service ClusterIP、跨节点 pod 网络、NFS 卷挂载、出网（本次的测试脚本思路：起一个用本地已有镜像的 pod，`nslookup`、`nc -z 10.96.0.1 443`、`nc -z <coredns pod IP> 53`、`ls /nfs`、`wget` 外网）。 <!-- check_repo: allow（10.96.0.1 是 kubeadm 默认的 kubernetes Service ClusterIP，非敏感） -->

## 3. 推荐顺序（允许整体中断时）
1. 所有节点：`k8s.sh backup`（etcd 快照、/etc/kubernetes、二进制、pod 列表；**会自动 pin K8s 组件版本**）+ `backup.sh`。
2. 所有节点并行：`prep-el7.sh repos/update/pipfix/inhibitors`（update 已排除 kube*/docker*）。
3. update 装了新内核的：`prep-el7.sh netmgr` → `k8s.sh nm` → `k8s.sh stop` → 重启进新 EL7 内核。**master 一台一台重启**（保住 etcd 多数派），worker 先 `kubectl drain`。
4. **worker 先走**：`kubectl drain --ignore-daemonsets --delete-emptydir-data --force` → `k8s.sh nfs-off` → `hop.sh` 7→8→9；金丝雀 worker 先到 EL10 做验证，其余 worker 跟上。此时控制面还在 EL7，可以验证新节点。
5. **master 再走**（3 台可并行，控制面会全停）。NFS 服务端所在节点最先保证起来。
6. 全部到 EL10：每台 `k8s.sh fix` → 检查 etcd `endpoint health`、`kubectl get nodes` → `kubectl uncordon` → `k8s.sh pods`（与升级前按 namespace 对比）。
7. 每台 `k8s.sh nfs-on`，宿主机业务按常规 `verify.sh`。

## 4. 本次踩到的坑（都已进脚本或文档）
| 现象 | 原因 | 处理 |
|---|---|---|
| 7→8 preupgrade 阻断 `Use of NFS detected` | pod 的 NFS PVC 挂载在节点上；fstab 里有 NFS | 先 drain（pod 走了挂载才会消失），再 `k8s.sh nfs-off`（注释 fstab 的 NFS、卸载），EL10 后 `k8s.sh nfs-on` |
| `hop.sh post` 的 `dnf upgrade` 可能把 kubelet/kubeadm 升到新 minor | kubernetes.repo 还开着 | `k8s.sh pin`（backup 自动做）：在 k8s 源里 exclude kubelet/kubeadm/kubectl/kubernetes-cni/cri-tools |
| 切到 NetworkManager 后 NM 给 cni0/veth 建 "Wired connection" | NM 默认接管新网卡 | `k8s.sh nm`：`unmanaged-devices` 排除 cni0/flannel*/veth*/docker*/kube-ipvs0/cali* 等 |
| EL8+ 上 ipvs 模块不再开机加载 | `/etc/sysconfig/modules/*.modules` 只有 EL7 的 initscripts 执行；`nf_conntrack_ipv4` 在 4.19+ 已并入 `nf_conntrack` | `k8s.sh fix` 写 `/etc/modules-load.d/k8s.conf` |
| kubelet 起不来：`Failed to start ContainerManager ... no PodsandBox found with Id` | 升级重启中途留下 **Dead** 状态的 `k8s_` 容器（`--filter status=exited` 抓不到） | `k8s.sh fix` 自动删 Dead 容器；手工：`docker ps -a --filter status=dead -q \| xargs docker rm -f` |
| 业务 Java pod 反复 OOMKilled / CrashLoop | **cgroup v2 下老 JDK（8u372、11.0.16 之前）认不出容器内存限制**，按宿主机内存算堆；本次镜像用 `-XX:MaxRAMPercentage=70` → 61G 主机上堆 = 43G，而 limit 只有 2G | `k8s.sh jvm-maxram <ns,...>`：给有内存 limit 的容器注入 `JAVA_TOOL_OPTIONS=-XX:MaxRAM=$(limits.memory)`（downward API），恢复 cgroup v1 时的堆大小；长期方案是基础镜像升到 8u372+/11.0.16+/17+。**注意 CI 重新发布时这个 env 会丢，要同步进发布模板** |
| 打完补丁后所有 worker CPU 100%、大量 pod 一直 not Ready | 60 个 Spring Boot 同时启动，再加上滚动更新 `maxSurge=1,maxUnavailable=0` 让新旧 pod 同时启动；liveness 探针把慢启动的杀掉 → 永远起不来 | 旧 ReplicaSet 的 pod 本来就会 OOM，直接 `kubectl scale rs <旧> --replicas=0`；必要时按 namespace 分批放开 |
| `nfs-client-provisioner` ImagePullBackOff | 镜像 tag 是 `:latest` → 默认 `imagePullPolicy: Always`，quay.io 拉不到；节点上其实有镜像 | 改 `imagePullPolicy: IfNotPresent`（同步改用户保存的 manifest） |
| `kubectl drain --force` 后少了 pod | 没有控制器管理的裸 pod 被删除且不会回来 | drain 前 `kubectl get pods -A -o json` 找 `ownerReferences` 为空的 pod，告诉用户 |
| worker 被 drain 后剩下那台负载 300+ | 前两台 drain 的 pod 全挤到最后一台 | 资源不够时直接全部 cordon 而不是逐台 drain；反正要整体中断 |
| master 8→9 进 emergency | fstab 里 bind 到 /sys 的条目（阿里云 `set_ecs_special.sh`） | 见 recovery.md B2；`hop.sh up` 已自动处理 |

## 5. 恢复后检查清单
- `kubectl get nodes -o wide`：全部 Ready，OS-IMAGE 为 AlmaLinux 10.2，CONTAINER-RUNTIME docker://29.x
- etcd：`docker exec <etcd> etcdctl ... endpoint health` 三个都 healthy
- `k8s.sh pods`：各 namespace Running 数与升级前一致；不是 Running 的逐个看 `describe`/`logs`
- 宿主机层：NFS 服务端 `exportfs -v`；fstab 恢复（`k8s.sh nfs-on`、`#osup-bind#` 已还原）；`verify.sh`
