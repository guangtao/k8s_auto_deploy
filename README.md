# k8s-deploy —— K8s 集群离线自动化部署 / 升级 v3.0（x86_64 / aarch64）

替代 `k8s-base-auto-deploy-2.1.2`（x86）与 `2.1.2-arm-release`（ARM）两套代码：
- **一套代码**同时支持 x86、ARM 和 x86+ARM 混合集群，节点架构和系统在运行时自动识别
- 全离线：KubeKey + Harbor，镜像以**多架构 manifest list** 推送，x86/ARM 节点共用同一个 tag
- 每一步都可以重复执行：已完成的步骤会自动跳过，失败后修复并重跑该步即可
- 内置升级子命令（kubeadm 滚动升级），与部署共用同一份配置

## 一、快速开始

```bash
# 1) 整理离线包（只需做一次；默认硬链接：瞬间完成、不占空间、不改动原目录）
bash deploy.sh migrate-pkg \
  --x86 ../k8s-base-auto-deploy-2.1.2-release_kubevip/k8s-base-auto-deploy-2.1.2-release-kubevip \
  --arm ../k8s-base-auto-deploy-2.1.2-arm-release_kubevip/k8s-base-auto-deploy-2.1.2-arm-release
# 可以先加 --dry-run 只看计划

# 2) 修改配置：scripts/render_config.py 中的 config 字典

# 3) 一键部署
bash deploy.sh install        # 关键步骤会二次确认；加 -y 为全自动
```

也可以单步执行：`bash deploy.sh precheck | os | reboot | runtime | images | lb | k8s | storage | addons | postcheck`

## 二、部署流程

| 步骤 | 命令 | 内容 | 重复执行 |
|---|---|---|---|
| 00 | `bootstrap` | 部署机离线安装 python3、jinja2、sshpass（自动识别本机系统和架构） | 已安装则跳过 |
| — | `facts` | SSH 探测每个节点的架构、系统、内核、cgroup、网卡，写入 `config/facts.*` | 每次刷新 |
| 01 | `precheck` | 离线包是否齐全（按集群用到的架构）、SSH、内核、防火墙、DNS、端口、资源、时间差、VIP 是否占用、各节点到 Harbor 的连通性 | 只读 |
| 02 | `os` | 按「系统+架构」安装依赖包（节点并行）；可选：CentOS7 x86 升级 kernel-lt | 有完成标记 |
| 03 | `reboot` | 只重启 02 步标记的节点，等待恢复后校验内核；部署机所在节点最后重启 | 不会重复重启 |
| 04 | `runtime` | docker 24.0.9 + containerd（systemd cgroup、certs.d），按架构下发；独立部署机也会安装 | 已运行则只更新配置 |
| 05 | `images` | 自动创建 Harbor 项目 → 多架构推送 → 检查每个镜像是否覆盖集群里的所有架构 → 校验关键镜像 | 覆盖推送 |
| 06 | `lb` | 仅 `lb.mode=keepalived`：master 上用容器运行 keepalived（单播 VRRP + apiserver 健康检查） | 重建容器 |
| 07 | `k8s` | 渲染 kk 配置（每个 host 带 arch）→ 解压所需架构的 artifact → `kk create cluster` → 等待节点 Ready | 集群已存在则跳过（`--force` 强制重跑） |
| 08 | `storage` | Longhorn（iscsi + 部署 + 等待就绪）/ NFS（客户端、可选自动配置服务端、provisioner）、默认 StorageClass | apply 幂等 |
| 09 | `addons` | metrics-server；apiserver 审计（逐台 master，失败自动还原，已配置则跳过） | 幂等 |
| 10 | `postcheck` | 节点、架构、组件、镜像来源、VIP、**真实 PVC 挂载测试**、metrics、审计日志 | 只读 |
| 99 | `uninstall` | kk delete cluster（需输入 DELETE 确认） | — |

## 三、配置要点（`scripts/render_config.py`）

| 配置项 | 说明 |
|---|---|
| `host.nodes[].arch` | 可省略，自动探测；混合集群中 x86 和 ARM 节点直接写在一起即可 |
| `os_type` | `auto`（推荐，每个节点单独识别），或强制指定 centos/kylin/uos/ubuntu/openeuler/rockey |
| `harbor.scheme` | `https`（自签证书，跳过校验）或 `http`；会同时生成 docker / containerd / kk 的仓库配置 |
| `lb.mode` | `none` 单 master；`kube-vip` KubeKey 内置（多 master 推荐）；`haproxy` KubeKey 内置本地代理；`keepalived` 本工具提供 VIP |
| `storage.longhorn` / `storage.nfs` | 可同时启用；默认 StorageClass 只能设一个 |
| `kernel.upgrade` | 仅对 CentOS 7 + x86 + 3.10 内核的节点生效 |
| `upgrade.*` | 升级子命令使用，见第五节 |

渲染时会校验配置，以下情况直接报错：
- 节点名或 IP 重复，角色中引用了不存在的节点
- etcd 节点数为偶数
- 多 master 却没有配置 LB
- VIP 与节点 IP 相同
- 两个默认 StorageClass
- 升级路径跨越超过 1 个小版本

## 四、目录结构

```
k8s-deploy/
├── deploy.sh                  # 唯一入口
├── scripts/
│   ├── render_config.py       # 配置 + 渲染
│   ├── lib/common.sh          # SSH/sudo、节点/架构/系统识别、离线包映射、并行执行、kubectl
│   ├── lib/images.sh          # 多架构镜像推送（部署和升级共用）
│   ├── install/00~10, 99      # 部署步骤
│   ├── upgrade/               # 升级子命令
│   └── tools/migrate_pkg.sh   # 2.1.2 安装包整理工具
├── template/                  # kk / 运行时 / Longhorn / NFS / metrics-server / 审计 模板
├── config/                    # 渲染产物（inventory.sh、facts、kk/cluster.yaml ...）
├── pkg/{amd64,arm64}/         # 离线包：kk, artifact/, docker/, images/, os/, kernel/, bootstrap/
├── upgrade-pkg/               # 升级离线包
├── work/                      # kk 工作目录
└── logs/                      # 每一步的日志 + state 记录
```

## 五、升级

```bash
bash deploy.sh upgrade build -v 1.34.2 -a amd64,arm64    # 联网机器上制作升级包
# 拷贝 upgrade-pkg/v1.34.2 到部署机后：
bash deploy.sh upgrade all                               # 推镜像 → 预检 → 备份 → 滚动升级 → 后检
bash deploy.sh upgrade rollback --node node2             # 节点级紧急回滚
```

滚动顺序：
1. 第一台 master 执行 `kubeadm upgrade apply`；
2. 其余 master 逐台执行 `upgrade node`；
3. 各 master 升级 kubelet；
4. worker 分批执行 drain → 升级 → uncordon。

升级时，审计配置通过 kubeadm `--patches` 保留。

## 六、相对 2.1.2 修复的问题

- x86 和 ARM 两套代码分别维护 → 合并为一套，按架构自动选包
- 镜像推送时去掉仓库前缀，两种架构的同名镜像互相覆盖 → 改为多架构 manifest list，并归一化 tag 上的架构后缀（如 `metrics-server:v0.7.2-linux-amd64`）
- metrics-server 镜像写死为 amd64、ARM 包里混入了 x86 内核 → 按架构取包，并在推送时校验每个镜像的实际架构
- `os_type` 全局只能设一个值 → 每个节点单独识别
- `post_comment_internal_lb` 路径错误、渲染出的配置是旧的 → 改为渲染时校验，kk 配置在 07 步按探测结果渲染
- 审计脚本不能重复执行、`auth_choice` 编号与其它脚本不一致、kubeadm 升级后审计配置丢失 → 已全部修复
- 后检检查的 StorageClass 名与实际部署的不一致，组件检查只要一个 Pod Running 就算通过 → 重写后检，加入真实 PVC 挂载测试
- `nfs` 部署脚本实际 apply 的是 longhorn.yaml，并且假设部署机就是 NFS 服务器 → NFS 与 Longhorn 拆开处理，NFS 服务端可指定节点
- keepalived 网卡写死 `eth0`、依赖组播 → 自动识别网卡，改用单播 VRRP
- `docker.service` 中 `\$MAINPID` 转义错误
- 部署机必须是集群节点 → 支持独立部署机（自动安装 docker、拷贝 kubeconfig、写 hosts）

## 七、已知限制 / 待验证

1. **还没有在真实集群上完整跑过。** 在容器 + sshd 中做了以下验证：
   - SSH 层：auth 1/2，包括特殊字符密码
   - facts、02、04 步，以及重复执行时的跳过逻辑
   - 审计 sed 改写结果为合法 YAML
   - 所有模板的渲染与 YAML 校验、配置校验规则

   kk、Longhorn 等集群相关步骤需要在测试环境上验证，**建议 x86、ARM、混合架构各跑一次**。
2. Harbor 需要预先存在（与 2.1.2 一致）。ARM 包中没有 Harbor 离线安装包。
3. `keepalived` 模式依赖镜像 `osixia/keepalived` 的配置路径 `/container/service/keepalived/assets/`。多 master 场景优先建议用 `kube-vip`（KubeKey 内置）。
4. ARM 包中没有 metrics-server 镜像。只有 ARM 节点时，09 步会提示并跳过；混合集群中 09 步会自动加 nodeSelector，把它限制到有镜像的架构上。补齐 ARM 镜像后重跑 05、09 步即可。
5. 系统依赖包沿用 2.1.2 的 `*.tar` + `rpm.sh`。目前 ARM 只有 Kylin 的 bootstrap 包，其它 ARM 系统的部署机需要预先装好 python3 和 jinja2。

## 八、打包机出包（Linux，需要 docker + 外网）

代码仓库只放代码，**离线包和镜像不进 git**（见 `.gitignore`）。推荐做法是：**先把已有的离线包整体传到打包机，打包机只下载缺的部分**。

```bash
# ① 已有离线包所在机器：把 pkg/ 打成一个 tar
#    Windows: 运行 pack_pkg.cmd（使用系统自带 tar）
#    Linux:   tar cf k8s-pkg.tar pkg/amd64 pkg/arm64 pkg/STATUS.md

# ② 打包机
git clone -b dgt https://github.com/guangtao/k8s_auto_deploy.git k8s-deploy && cd k8s-deploy
tar xf /path/to/k8s-pkg-all-<日期>.tar             # 解压到仓库根目录，得到 pkg/amd64、pkg/arm64

bash deploy.sh fetch-images --plan                  # 列出缺哪些镜像（按 tar 内真实镜像名+架构判断，不看文件名）
bash deploy.sh fetch-images                         # 只下载缺的；docker.io 慢可加 --mirror docker.m.daocloud.io
bash deploy.sh verify-pkg                           # 两种架构都应 FAIL=0
bash deploy.sh bundle -a amd64,arm64                # 出包；纯 x86 现场 -a amd64，纯 ARM 现场 -a arm64
```

基于 2.1.2 安装包整理出的离线包，按 `images/images-v1.33.4.txt` 对比，只缺 6 个镜像：
- amd64：backing-image-manager:v1.9.1
- arm64：backing-image-manager、support-bundle-kit、metrics-server、nfs-subdir-external-provisioner、keepalived（osixia/keepalived 可能没有 arm64 版本，ARM 集群用 kube-vip 即可）

没有现成离线包时也可以从零开始：`deploy.sh migrate-pkg` 整理 2.1.2 安装包（kk、制品、docker、系统包），再执行 `fetch-images` 拉取全部镜像。

镜像清单 `images/images-v1.33.4.txt` 按用途分组（核心 / Calico / LocalPV / 高可用 / Longhorn / 插件 / 其它网络插件），按需取消注释。
推送到 Harbor 时只保留 `name:tag`，所以清单里的仓库地址可以换成任何能访问的镜像站。

> 非镜像部分（系统依赖包）目前 ARM 只有 Kylin、UOS，且 UOS ARM 缺 iscsi 包；这些需要在对应 ARM 系统上用 yumdownloader 等工具单独制作，`fetch-images` 不涉及。
