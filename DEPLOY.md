# K8s 离线部署手册（从拿到部署包开始）

适用：`k8s-deploy-v1.33.4-<架构>-<日期>.tar.xz`（K8s v1.33.4 / Calico v3.27.4 / Longhorn v1.9.1，KubeKey 离线安装）

---

## 0. 先确认拿到的包对不对

| 包名中的架构 | 适用现场 |
|---|---|
| `amd64` | 全部节点都是 x86_64 |
| `arm64` | 全部节点都是 aarch64（鲲鹏、飞腾等） |
| `amd64-arm64` | x86 + ARM 混合集群 |

- **部署机**是执行本工具的那台机器，可以是集群节点，也可以是独立机器。它的架构必须包含在包名里。比如 `arm64` 包不能在 x86 部署机上执行。
- 一起拿到的文件：
  - `*.tar.xz`，大包可能已切成 `*.tar.xz.part00`、`part01` ……
  - `*.sha256`
  - `*.DEPLOY.md`（即本文）
- 包里的 `BUNDLE_INFO.txt` 记录了代码版本、出包时间和包含的镜像清单。

支持的操作系统：

| 架构 | 系统 |
|---|---|
| x86_64 | CentOS 7、Kylin V10、UOS、Ubuntu、openEuler、Rocky |
| aarch64 | Kylin V10、UOS |

UOS ARM 没有 iscsi 包。使用 Longhorn 时，需要事先在 UOS ARM 节点上装好 `iscsi-initiator-utils` / `open-iscsi`。


### 部署了哪些模块

| 模块 | 版本 | 作用 | 是否部署 | 对应配置 |
|---|---|---|---|---|
| Kubernetes（kubeadm / kubelet / kubectl） | v1.33.4 | 集群本体，KubeKey 离线安装 | 默认 | `kubernetes`、`roles` |
| etcd | 随 KubeKey 制品 | 集群数据存储 | 默认 | `etcd.data_dir` |
| containerd | 1.7.13 | 节点容器运行时 | 默认 | `kubernetes.container_manager` |
| Docker + docker-compose | 24.0.9 | 推送镜像、运行 Harbor（部署机和仓库节点） | 默认 | `host.docker_data_root` |
| Calico | v3.27.4 | Pod 网络 | 默认 | `kubernetes.network_plugin` |
| CoreDNS + NodeLocal DNS | 1.9.3 / 1.22.20 | 集群 DNS 与节点 DNS 缓存 | 默认 | — |
| OpenEBS LocalPV | 3.3.0 | KubeKey 自带本地盘存储类 | 默认 | — |
| Harbor | x86 2.10.2 / ARM 2.10.1 | 镜像仓库 | 可选 | `harbor.install=True` |
| Longhorn | v1.9.1 | 分布式块存储，默认存储类 | 默认开启 | `storage.longhorn.enabled` |
| NFS 动态供给 | v4.0.2 | NFS 存储类 | 可选 | `storage.nfs.enabled` |
| 控制面高可用 | kube-vip v0.7.2 / haproxy 2.9.6 / keepalived | 多 master 的 VIP 或本地代理 | 多 master 时 | `lb.mode` |
| metrics-server | v0.7.2 | `kubectl top`、HPA | 默认开启 | `addons.metrics_server.enabled` |
| apiserver 审计日志 | — | 记录 API 操作到 `/var/log/kubernetes/audit.log` | 默认开启 | `addons.audit.enabled` |

另外，每个节点会先做系统初始化：
- 安装依赖包；
- 关闭 swap、防火墙和 SELinux；
- 设置内核参数；
- CentOS 7 x86 可选升级内核。

---

## 1. 部署机准备

| 项目 | 要求 |
|---|---|
| 用户 | root（或可 sudo 的用户以 `sudo -i` 执行） |
| 磁盘 | 解压目录所在分区可用空间 ≥ 包大小 × 4，docker 数据目录（默认 `/data/docker`）≥ 镜像大小 × 2 |
| 网络 | 能 SSH 到所有节点；所有节点之间网络互通；节点时间差 < 5 秒 |
| 命令 | `tar`、`xz`、`sha256sum`（系统自带）。python3 / jinja2 / sshpass 没有也不要紧，第 3 步离线安装 |

所有节点：
- 主机名不重复；
- 关闭 swap 和防火墙由工具自动完成（02 步）；
- 建议每台数据盘挂载到 `/data`。

---

## 2. 校验、解压

把所有文件拷到部署机同一个目录，例如 `/opt`：

```bash
cd /opt

# 未分卷
sha256sum -c k8s-deploy-v1.33.4-arm64-20261012.sha256

# 分卷：先校验各分卷，合并后再校验整包
sha256sum -c --ignore-missing k8s-deploy-v1.33.4-arm64-20261012.sha256
cat k8s-deploy-v1.33.4-arm64-20261012.tar.xz.part* > k8s-deploy-v1.33.4-arm64-20261012.tar.xz
sha256sum -c --ignore-missing k8s-deploy-v1.33.4-arm64-20261012.sha256
rm -f k8s-deploy-v1.33.4-arm64-20261012.tar.xz.part*        # 可选，释放空间

# 解压（几分钟），得到 /opt/k8s-deploy
tar xf k8s-deploy-v1.33.4-arm64-20261012.tar.xz
cd k8s-deploy
cat BUNDLE_INFO.txt | head -8
```

> 如果是 `.tar.zst` 包，解压命令改为 `tar -I zstd -xf <包名>`，需要现场有 zstd。

之后的所有命令都在 `/opt/k8s-deploy` 目录下执行。

---

## 3. 部署机初始化

```bash
bash deploy.sh bootstrap          # 离线安装 python3、jinja2、sshpass（已安装则跳过）
bash deploy.sh verify-pkg         # 检查离线包：架构、完整性、必需镜像（应为 FAIL=0）
```

---

## 4. 修改配置

编辑 `scripts/render_config.py` 中的 `config` 字典，然后执行 `bash deploy.sh render`。render 会校验配置，有错误会直接提示。

### 4.1 必改项

```python
'deploy_host': '192.168.10.11',          # 部署机 IP
'host': {
    'nodes': [                            # 所有节点；arch 不用写，自动识别
        {'name': 'master1', 'host': '192.168.10.11', 'user': 'root', 'passwd': 'xxx', 'key_dir': '/root/.ssh/id_rsa'},
        {'name': 'master2', 'host': '192.168.10.12', 'user': 'root', 'passwd': 'xxx', 'key_dir': '/root/.ssh/id_rsa'},
        {'name': 'master3', 'host': '192.168.10.13', 'user': 'root', 'passwd': 'xxx', 'key_dir': '/root/.ssh/id_rsa'},
        {'name': 'worker1', 'host': '192.168.10.21', 'user': 'root', 'passwd': 'xxx', 'key_dir': '/root/.ssh/id_rsa'},
    ],
    'auth_choice': '1',                   # 1 root+密码  2 普通用户+密码+sudo  3 SSH 密钥
},
'roles': {
    'etcd':   ['master1', 'master2', 'master3'],   # 奇数个
    'master': ['master1', 'master2', 'master3'],
    'worker': ['master1', 'master2', 'master3', 'worker1'],
},
```

### 4.2 镜像仓库（二选一）

**A. 现场已有 Harbor：**

```python
'harbor': {'registry': '192.168.10.5', 'scheme': 'https', 'project': 'kubesphereio',
           'user': 'admin', 'passwd': '现场密码', 'create_project': True, 'install': False, ...}
```

**B. 由本工具顺便部署 Harbor（04b 步）：**

```python
'harbor': {'registry': '192.168.10.11',  # = 仓库节点的 IP
           'scheme': 'https', 'project': 'kubesphereio',
           'user': 'admin', 'passwd': 'Harbor@2026',   # 作为 admin 初始密码，8~128 位，同时含大写、小写字母和数字
           'install': True, 'node': 'master1',          # 装在哪个节点；留空 = 部署机
           'type': 'auto', 'data_dir': '/data/harbor'}
```

`type: auto` 的含义：
- x86 节点装 Harbor 2.10.2；
- ARM 节点装包里的 Harbor aarch64 v2.10.1（社区版）；
- 出包时如果用了 `--no-harbor`，自动改装 registry:2（无账号认证）。

仓库节点的 80/443 端口必须空闲。

### 4.3 控制面高可用

| 场景 | 配置 |
|---|---|
| 单 master | `'lb': {'mode': 'none'}` |
| 多 master（**推荐**） | `'lb': {'mode': 'kube-vip', 'vip': '192.168.10.100'}`，VIP 必须是同网段空闲 IP |
| 多 master，无法用 VIP | `'lb': {'mode': 'haproxy'}`，每个 worker 本地代理 |
| 多 master，keepalived | `'lb': {'mode': 'keepalived', 'vip': '...'}`，**仅 x86**，ARM master 不支持 |

### 4.4 存储与其它

- `storage.longhorn.enabled`：默认 True。
  - `replicas` 不能大于 worker 数。
  - 数据目录 `data_path` 建议放数据盘。
- `storage.nfs`：需要 NFS 时启用。
  - 填 `server` / `path`；
  - 如果 NFS 服务器是集群节点，填 `server_node`，工具会自动配置 exports。
- `kubernetes.pods_cidr` / `service_cidr`：不能与现场网段冲突。
- `kernel.upgrade`：默认 True，只对 CentOS 7 x86 生效，升级到 kernel-lt 5.4 并重启节点。K8s v1.33 要求内核 ≥ 4.15，CentOS 7 自带的 3.10 内核装不上，不要关掉。

```bash
bash deploy.sh render      # 渲染并校验配置
bash deploy.sh facts       # 探测每个节点的架构/系统/内核（检查 SSH 是否都通）
bash deploy.sh precheck    # 部署前检查：全部 OK 或只有 WARN 再继续
```

precheck 的 FAIL 项都带有原因说明。修复后重跑 precheck。

---

## 5. 部署

### 一键部署（推荐）

```bash
bash deploy.sh install        # 关键步骤会二次确认
# bash deploy.sh install -y   # 全自动，不确认
```

整个过程约 30~60 分钟，主要耗时在镜像推送和 Longhorn 拉起。

**需要重启时（CentOS 7 x86 节点会升级内核并重启，其它系统不需要）：**
- **其它节点：** 逐台自动重启，等它真正重启完成（以 boot_id 判断）、内核生效后自动继续，流程不中断。
- **部署机本身：** 如果它也是要重启的节点，会放在最后重启。
  - 用 `-y` 执行时，重启前会注册一次性服务 `k8s-deploy-resume`，开机约 1 分钟后自动继续执行 `install -y`，执行一次后自动删除。
  - 不加 `-y` 时会先询问是否自动续跑；选否，则重启后需手动再执行一次 `bash deploy.sh install`。
  - 已完成的步骤都会跳过，内核不会重装，节点也不会再重启。
  - 查看自动续跑的进度：`tail -f logs/install-resume-*.log`；查看状态：`systemctl status k8s-deploy-resume`。
  - 续跑期间如果再手动执行 install，会提示已有任务在运行，不会重复执行。

### 或者分步执行（便于定位问题）

| 步骤 | 命令 | 部署的模块 / 做什么 | 作用范围 | 大约耗时 | 验证 |
|---|---|---|---|---|---|
| 00 | `bash deploy.sh bootstrap` | 离线安装 python3、jinja2、sshpass | 部署机 | 1 分钟 | `python3 -c 'import jinja2'` 不报错 |
| — | `bash deploy.sh render` | 校验并渲染配置，生成 `config/inventory.sh` | 部署机 | 秒级 | 无 `[ERROR]` |
| — | `bash deploy.sh facts` | 识别每台节点的架构、系统、内核、网卡 | 所有节点 | 秒级 | 列出每台节点的 arch / os / kernel |
| 01 | `bash deploy.sh precheck` | 部署前检查（只读） | 所有节点 | 1 分钟 | 汇总 `FAIL=0` |
| 02 | `bash deploy.sh os` | 依赖包、关 swap/防火墙/SELinux、内核参数；CentOS 7 x86 安装 kernel-lt 5.4 | K8s 节点 | 2~5 分钟 | 节点上 `swapon --show` 无输出 |
| 03 | `bash deploy.sh reboot` | 只重启装了新内核的节点，等待恢复并校验内核 | 需重启的节点 | 视情况 | 节点上 `uname -r` 为 5.4 开头 |
| 04 | `bash deploy.sh runtime` | Docker 24.0.9 + containerd，配置仓库信任 | K8s 节点、部署机、仓库节点 | 2~5 分钟 | `docker info`、`containerd --version` 正常 |
| 04b | `bash deploy.sh registry` | Harbor（ARM 无安装包时为 registry:2）+ 自签证书；仅 `harbor.install=True` | 仓库节点 | 5~10 分钟 | `curl -k https://<仓库IP>/api/v2.0/health` 为 healthy |
| 05 | `bash deploy.sh images` | 镜像以多架构 manifest 推到 Harbor 的 `harbor.project` | 部署机 → Harbor | 10~30 分钟 | "关键镜像校验"全部 OK |
| 06 | `bash deploy.sh lb` | keepalived VIP；仅 `lb.mode=keepalived` | master | 1 分钟 | `ip addr` 能看到 VIP |
| 07 | `bash deploy.sh k8s` | KubeKey 建集群：etcd、控制面、kubelet、Calico、CoreDNS、NodeLocal DNS、OpenEBS LocalPV、kube-vip/haproxy | K8s 节点 | 10~20 分钟 | `kubectl get nodes` 全部 Ready |
| 08 | `bash deploy.sh storage` | Longhorn（含 iscsi）/ NFS 动态供给，默认存储类 | K8s 节点 | 5~10 分钟 | `kubectl -n longhorn-system get pod` 全部 Running；`kubectl get sc` 有 default |
| 09 | `bash deploy.sh addons` | metrics-server；apiserver 审计日志（逐台 master，失败自动还原） | 集群 / master | 2~5 分钟 | `kubectl top nodes` 有数据；master 上有 `/var/log/kubernetes/audit.log` |
| 10 | `bash deploy.sh postcheck` | 部署后检查（含真实 PVC 挂载测试） | 集群 | 2 分钟 | 全部 OK |

修改配置后，先执行 `render`，再重跑受影响的步骤。例如改了 Harbor 地址，要重跑 04 和 05。07 步需要强制重跑时，用 `bash deploy.sh k8s --force`。

每一步都可以重复执行。某一步失败时：
1. 看屏幕上的 ERROR 和 `logs/` 下对应的日志；
2. 修复问题；
3. 重跑**该步**即可。

---

## 6. 部署后验证

```bash
bash deploy.sh postcheck                    # 全部 OK 即部署成功
kubectl get nodes -o wide                   # 所有节点 Ready，ARCH 列与实际一致
kubectl get pods -A | grep -v Running       # 除 Completed 外不应有其它状态
kubectl get sc                              # longhorn (default)
kubectl top nodes                           # metrics-server 正常
```

- Harbor 控制台：`https://<harbor.registry>`，账号 `admin` / `harbor.passwd`。
- Longhorn 控制台：`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`，然后访问部署机的 8080 端口。

---

## 7. 常见问题

| 现象 | 处理 |
|---|---|
| `sha256sum` 校验失败 | 包传输损坏，重新拷贝（U 盘建议 exFAT/NTFS，或出包时用 `--split 4G`） |
| `tar xf` 报 `xz: Cannot allocate memory` | 部署机内存过小，`xz -dc 包名 \| tar xf -` 也不行时，换一台内存 ≥ 2G 的机器解压 |
| verify-pkg 报缺少镜像 | 打包机执行 `deploy.sh fetch-images -a <arch>` 补齐后重新出包 |
| precheck：SSH 失败 | 检查 `auth_choice` 与账号密码；auth 2 需要用户有免密 sudo 或 sudo 密码同登录密码 |
| precheck：VIP 已被占用 | 换一个空闲 IP |
| precheck：端口被占用（仓库节点 80/443） | 停掉占用端口的服务，或把 Harbor 装到其它节点（`harbor.node`） |
| 05 镜像推送失败 `x509` / `http: server gave HTTP response` | `harbor.scheme` 与 Harbor 实际协议不一致；改正后执行 `bash deploy.sh render && bash deploy.sh runtime && bash deploy.sh images` |
| 05 推送失败 `unauthorized` | Harbor 账号密码不对，或项目不存在且 `create_project=False` |
| 07 kk 卡在 `pull image` | 节点到 Harbor 不通，或镜像没推全；先跑 `bash deploy.sh images` 看校验结果 |
| 03 报"没有开始重启"或"未恢复" | 登录该节点（或看控制台）检查；处理后重跑 `bash deploy.sh install`，已重启完成的节点不会再重启 |
| 部署机重启后没有自动继续 | `systemctl status k8s-deploy-resume` 和 `logs/install-resume-*.log` 查看原因；手动执行 `bash deploy.sh install -y` 即可 |
| 07 失败想重来 | 修复后直接 `bash deploy.sh k8s`；已存在半成品集群时用 `bash deploy.sh k8s --force` |
| Longhorn Pod 一直 Init / CrashLoop | 节点缺 iscsi（`systemctl status iscsid`）；UOS ARM 需要手工装 open-iscsi |
| ARM 集群 metrics-server 不起 | 确认 `pkg/arm64/images/IMAGES.txt` 中有 `metrics-server:v0.7.2`，然后重跑 `images`、`addons` |

日志位置：
- 每一步的日志：`logs/<步骤>-<时间>.log`；
- KubeKey 的完整输出：`logs/kk-create.log`；
- 各节点上下发的文件和远程日志（如 Harbor 安装日志）：`/var/lib/k8s-upgrade-work/`。

---

## 8. 卸载 / 重装

```bash
bash deploy.sh uninstall      # kk delete cluster，需要输入 DELETE 确认
```

- 卸载不会删除 Harbor、docker 和 `/data` 下的数据；
- 重装时直接从第 5 节重新执行 `install`。

## 9. 后续升级

见 `README.md` 第五节。
- 在打包机执行 `deploy.sh upgrade build` 制作升级包；
- 把升级包拷到 `upgrade-pkg/` 下，然后执行 `bash deploy.sh upgrade all`。
