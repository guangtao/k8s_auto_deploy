# shellcheck shell=bash
# ============================================================
# k8s-deploy 公共函数库（部署 / 升级脚本共用）
#   - 统一 SSH/SCP（auth_choice 1/2/3 语义与安装项目一致）
#   - 远程命令统一以 root 执行（auth 2 自动 sudo）
#   - kubectl 包装、版本/架构工具函数、日志
# ============================================================

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
INVENTORY="$ROOT_DIR/config/inventory.sh"
PATCH_DIR_LOCAL="$ROOT_DIR/config/patches"
REMOTE_WORK="/var/lib/k8s-upgrade-work"   # root 工作目录（下发的二进制等）
REMOTE_PATCH_DIR="/etc/kubernetes/upgrade-patches"

if [ ! -f "$INVENTORY" ]; then
    echo "[ERROR] 未找到 $INVENTORY，请先执行: bash deploy.sh render" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$INVENTORY"

DEPLOY_PKG_DIR="$ROOT_DIR/pkg"          # 部署离线包: pkg/<arch>/...
WORK_DIR="$ROOT_DIR/work"                # kk 工作目录
RENDERED="$ROOT_DIR/config"              # 渲染产物
FACTS_FILE="$ROOT_DIR/config/facts.sh"
case "$UPGRADE_PKG_DIR_CFG" in
    /*) PKG_DIR="$UPGRADE_PKG_DIR_CFG" ;;
    *)  PKG_DIR="$(cd "$ROOT_DIR" && mkdir -p "$UPGRADE_PKG_DIR_CFG" && cd "$UPGRADE_PKG_DIR_CFG" && pwd)" ;;
esac

LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"
STATE_FILE="$LOG_DIR/state"   # 记录最近一次备份时间戳等
touch "$STATE_FILE"

SSH_OPTS=(-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
SCP_OPTS=(-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10)

# ---------------- 日志 ----------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
_ts()      { date '+%F %T'; }
log_info() { echo -e "$(_ts) ${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "$(_ts) ${YELLOW}[WARN]${NC} $*"; }
log_error(){ echo -e "$(_ts) ${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "\n$(_ts) ${BLUE}========== $* ==========${NC}"; }
die()      { log_error "$*"; exit 1; }

# 把本脚本的全部输出同时写入日志文件
start_log() {
    local name=$1
    LOG_FILE="$LOG_DIR/${name}-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "日志文件: $LOG_FILE"
}

confirm() {
    local msg=$1
    [ "${ASSUME_YES:-false}" = "true" ] && return 0
    read -r -p "$msg [y/N]: " ans </dev/tty
    [[ "$ans" =~ ^[yY]$ ]]
}

state_set() {  # key value
    local k=$1 v=$2
    grep -v "^${k}=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
    echo "${k}=${v}" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}
state_get() { grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }

require_root() { [ "$EUID" -eq 0 ] || die "请使用 root 运行"; }

require_cmds() {
    local c
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"; done
}

# ---------------- 节点清单 ----------------
node_line() {
    local name=$1 line
    for line in "${NODES[@]}"; do
        [ "${line%%|*}" = "$name" ] && { echo "$line"; return 0; }
    done
    die "节点 $name 不在 inventory 中"
}
node_ip()   { local l; l=$(node_line "$1"); l=${l#*|}; echo "${l%%|*}"; }
all_nodes() { local line; for line in "${NODES[@]}"; do echo "${line%%|*}"; done; }
is_master() { local m; for m in "${MASTERS[@]}"; do [ "$m" = "$1" ] && return 0; done; return 1; }
# worker 中去掉 master（master 在控制面阶段已处理 kubelet）
pure_workers() { local w; for w in "${WORKERS[@]}"; do is_master "$w" || echo "$w"; done; }
# 去重后的全部 K8s 节点，master 在前
k8s_nodes() {
    local n seen=" "
    for n in "${MASTERS[@]}" "${WORKERS[@]}"; do
        [[ "$seen" == *" $n "* ]] && continue
        seen+="$n "; echo "$n"
    done
}

_local_ips=""
is_local_ip() {
    [ -z "$_local_ips" ] && _local_ips=" $(hostname -I 2>/dev/null) 127.0.0.1 "
    [[ "$_local_ips" == *" $1 "* ]]
}

# ---------------- 远程执行 ----------------
# 以普通身份执行（不 sudo），主要用于准备 stage 目录
_ssh_raw() {
    local name=$1 cmd=$2 _n ip user pass key _arch
    IFS='|' read -r _n ip user pass key _arch <<< "$(node_line "$name")"
    case "$AUTH_CHOICE" in
        1|2) SSHPASS="$pass" sshpass -e ssh "${SSH_OPTS[@]}" "$user@$ip" "$cmd" ;;
        3)   ssh -i "$key" "${SSH_OPTS[@]}" "$user@$ip" "$cmd" ;;
        *)   die "未知 auth_choice: $AUTH_CHOICE" ;;
    esac
}

# 以 root 执行任意多行脚本；命令用 base64 传输，避免多层引号转义问题
run_remote() {
    local name=$1 cmd=$2 _n ip user pass key _arch b64 remote
    IFS='|' read -r _n ip user pass key _arch <<< "$(node_line "$name")"
    if is_local_ip "$ip" && [ "$EUID" -eq 0 ]; then
        bash -c "$cmd"
        return $?
    fi
    b64=$(printf '%s' "$cmd" | base64 -w0)
    if [ "$AUTH_CHOICE" = "2" ] && [ "$user" != "root" ]; then
        local qpass=${pass//\'/\'\\\'\'}
        remote="f=\$(mktemp); echo $b64 | base64 -d > \$f; echo '$qpass' | sudo -S -p '' bash \$f; rc=\$?; rm -f \$f; exit \$rc"
    else
        remote="echo $b64 | base64 -d | bash"
    fi
    _ssh_raw "$name" "$remote"
}

# 拷贝本地文件/目录到远程任意路径（root 权限落盘）
copy_to() {
    local name=$1 src=$2 dst=$3 _n ip user pass key _arch base
    IFS='|' read -r _n ip user pass key _arch <<< "$(node_line "$name")"
    base=$(basename "$src")
    if is_local_ip "$ip" && [ "$EUID" -eq 0 ]; then
        mkdir -p "$(dirname "$dst")" && rm -rf "$dst" && cp -a "$src" "$dst"
        return $?
    fi
    # 按登录用户 + 本次传输隔离：避免 root 建的目录挡住普通用户，也避免并行传输互相覆盖
    local stage="/tmp/k8s-deploy-stage-$user/$$-$RANDOM$RANDOM"
    _ssh_raw "$name" "mkdir -p $stage" || return 1
    case "$AUTH_CHOICE" in
        1|2) SSHPASS="$pass" sshpass -e scp "${SCP_OPTS[@]}" -r "$src" "$user@$ip:$stage/" || return 1 ;;
        3)   scp -i "$key" "${SCP_OPTS[@]}" -r "$src" "$user@$ip:$stage/" || return 1 ;;
    esac
    run_remote "$name" "mkdir -p \$(dirname '$dst') && rm -rf '$dst' && mv '$stage/$base' '$dst' && chown -R root:root '$dst'; rmdir '$stage' 2>/dev/null; true"
}

# 从远程拷贝单个文件到本地目录
copy_from() {
    local name=$1 src=$2 dst_dir=$3 _n ip user pass key _arch base
    IFS='|' read -r _n ip user pass key _arch <<< "$(node_line "$name")"
    base=$(basename "$src")
    mkdir -p "$dst_dir"
    if is_local_ip "$ip" && [ "$EUID" -eq 0 ]; then
        cp -a "$src" "$dst_dir/" ; return $?
    fi
    local stage="/tmp/k8s-deploy-stage-$user/$$-$RANDOM$RANDOM" rc
    _ssh_raw "$name" "mkdir -p $stage" || return 1
    run_remote "$name" "cp -a '$src' '$stage/$base' && chown $user '$stage/$base'" || return 1
    case "$AUTH_CHOICE" in
        1|2) SSHPASS="$pass" sshpass -e scp "${SCP_OPTS[@]}" "$user@$ip:$stage/$base" "$dst_dir/" ;;
        3)   scp -i "$key" "${SCP_OPTS[@]}" "$user@$ip:$stage/$base" "$dst_dir/" ;;
    esac
    rc=$?
    run_remote "$name" "rm -rf '$stage'" >/dev/null 2>&1
    return $rc
}

check_ssh_tools() {
    if [ "$AUTH_CHOICE" = "1" ] || [ "$AUTH_CHOICE" = "2" ]; then
        require_cmds sshpass ssh scp
    else
        require_cmds ssh scp
    fi
}

# ---------------- kubectl ----------------
KC_MODE=""
init_kubectl() {
    if command -v kubectl >/dev/null 2>&1 && kubectl get --raw /readyz >/dev/null 2>&1; then
        KC_MODE=local
    else
        KC_MODE=remote
        run_remote "${MASTERS[0]}" "kubectl get --raw /readyz" >/dev/null 2>&1 \
            || die "本机与 ${MASTERS[0]} 均无法访问 apiserver"
        log_info "本机 kubectl 不可用，改为通过 ${MASTERS[0]} 执行 kubectl"
    fi
}
kc() {
    [ -z "$KC_MODE" ] && init_kubectl
    if [ "$KC_MODE" = local ]; then
        kubectl "$@"
    else
        run_remote "${MASTERS[0]}" "kubectl $(printf '%q ' "$@")"
    fi
}

wait_apiserver() {
    local timeout=${1:-300} i=0
    while [ $i -lt "$timeout" ]; do
        kc get --raw /readyz >/dev/null 2>&1 && return 0
        sleep 5; i=$((i + 5))
    done
    return 1
}

# ---------------- 版本 / 架构 ----------------
ver_minor() { local v=${1#v}; v=${v#*.}; echo "${v%%.*}"; }
# a >= b ?
ver_ge() { [ "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | head -1)" = "${2#v}" ]; }
ver_eq() { [ "${1#v}" = "${2#v}" ]; }

server_version() {
    kc get --raw /version 2>/dev/null | sed -n 's/.*"gitVersion": *"\(v[^"]*\)".*/\1/p' | head -1
}
# 某个 master 上 kube-apiserver 静态 Pod 的镜像版本
apiserver_version_on() {
    kc -n kube-system get pod "kube-apiserver-$1" \
        -o jsonpath='{.spec.containers[0].image}' 2>/dev/null | sed 's/.*://'
}
kubelet_version_of() {
    kc get node "$1" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null
}
node_ready() {
    [ "$(kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

declare -A _ARCH_CACHE
declare -A _OS_CACHE
# shellcheck source=/dev/null
[ -f "$FACTS_FILE" ] && source "$FACTS_FILE"   # 节点探测结果（deploy.sh facts 生成）

_detect_arch() {
    case "$1" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *)             echo "unknown($1)" ;;
    esac
}
# 架构优先级：inventory 配置 > facts > 实时探测
node_arch() {
    local name=$1 l cfg
    if [ -z "${_ARCH_CACHE[$name]:-}" ]; then
        l=$(node_line "$name"); cfg=${l##*|}
        if [ -n "$cfg" ] && [ "$cfg" != "$l" ]; then
            _ARCH_CACHE[$name]=$cfg
        elif [ -n "${FACT_ARCH[$name]:-}" ]; then
            _ARCH_CACHE[$name]=${FACT_ARCH[$name]}
        else
            _ARCH_CACHE[$name]=$(_detect_arch "$(run_remote "$name" "uname -m" 2>/dev/null | tr -d '\r')")
        fi
    fi
    echo "${_ARCH_CACHE[$name]}"
}

# 远程：识别操作系统，输出 centos/kylin/uos/ubuntu/openeuler/rockey/unknown
REMOTE_DETECT_OS='
. /etc/os-release 2>/dev/null
id=$(echo "${ID:-unknown}" | tr "A-Z" "a-z")
case "$id" in
    centos|rhel)              echo centos ;;
    kylin|neokylin)           echo kylin ;;
    uos|uniontech|deepin)     echo uos ;;
    ubuntu|debian)            echo ubuntu ;;
    openeuler)                echo openeuler ;;
    rocky)                    echo rockey ;;
    *)                        echo "unknown-$id" ;;
esac
'
node_os() {
    local name=$1
    if [ -z "${_OS_CACHE[$name]:-}" ]; then
        if [ "$OS_TYPE" != "auto" ]; then
            _OS_CACHE[$name]=$OS_TYPE
        elif [ -n "${FACT_OS[$name]:-}" ]; then
            _OS_CACHE[$name]=${FACT_OS[$name]}
        else
            _OS_CACHE[$name]=$(run_remote "$name" "$REMOTE_DETECT_OS" 2>/dev/null | tr -d '\r')
        fi
    fi
    echo "${_OS_CACHE[$name]}"
}

image_repo() {
    if [ -n "$IMAGE_REPOSITORY" ]; then
        echo "${IMAGE_REPOSITORY%/}"
    else
        echo "${HARBOR_REGISTRY%/}/${HARBOR_PROJECT}"
    fi
}
# 从集群 kubeadm-config 中读取 imageRepository
cluster_image_repo() {
    kc -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null \
        | sed -n 's/^imageRepository: *//p' | tr -d '"' | head -1
}

pkg_ver_dir() { echo "$PKG_DIR/v${1#v}"; }
pkg_bin()     { echo "$(pkg_ver_dir "$1")/$2/bin/$3"; }   # ver arch name
pkg_images_list() { echo "$(pkg_ver_dir "$1")/images.list"; }

# 远程：探测二进制安装路径（KubeKey 默认 /usr/local/bin）
REMOTE_DETECT_BINS='
KUBELET_BIN=$(systemctl show -p ExecStart kubelet 2>/dev/null | sed -n "s/.*path=\([^ ;]*\).*/\1/p")
[ -z "$KUBELET_BIN" ] && KUBELET_BIN=$(command -v kubelet || echo /usr/local/bin/kubelet)
KUBEADM_BIN=$(command -v kubeadm || echo /usr/local/bin/kubeadm)
KUBECTL_BIN=$(command -v kubectl || echo /usr/local/bin/kubectl)
'

# 同步 patches 目录（审计 / cgroup）到节点
sync_patches() {
    local name=$1
    if [ -d "$PATCH_DIR_LOCAL" ] && [ -n "$(ls -A "$PATCH_DIR_LOCAL" 2>/dev/null)" ]; then
        copy_to "$name" "$PATCH_DIR_LOCAL" "$REMOTE_PATCH_DIR" >&2 || return 1
        echo "--patches $REMOTE_PATCH_DIR"
    else
        run_remote "$name" "rm -rf $REMOTE_PATCH_DIR" >/dev/null 2>&1
        echo ""
    fi
}

# 远程：探测 etcd 证书（KubeKey 二进制 etcd 优先，其次 kubeadm 静态 Pod etcd）
REMOTE_ETCD_CERTS='
if [ -f /etc/ssl/etcd/ssl/ca.pem ]; then
    ETCD_CERT=$(ls /etc/ssl/etcd/ssl/admin-$(hostname)*.pem 2>/dev/null | grep -v -- -key | head -1)
    [ -z "$ETCD_CERT" ] && ETCD_CERT=$(ls /etc/ssl/etcd/ssl/admin-*.pem 2>/dev/null | grep -v -- -key | head -1)
    ETCD_KEY=${ETCD_CERT%.pem}-key.pem; ETCD_CA=/etc/ssl/etcd/ssl/ca.pem
else
    ETCD_CA=/etc/kubernetes/pki/etcd/ca.crt
    ETCD_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
    ETCD_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key
fi
ETCDCTL="env ETCDCTL_API=3 $(command -v etcdctl || echo /usr/local/bin/etcdctl) --endpoints=$EP --cacert=$ETCD_CA --cert=$ETCD_CERT --key=$ETCD_KEY"
'

# ============================================================
# 部署相关
# ============================================================
# 部署机伪节点（部署机不在集群中时由 inventory 自动加入）
has_deploy_pseudo() { local l; for l in "${NODES[@]}"; do [ "${l%%|*}" = "__deploy__" ] && return 0; done; return 1; }
# 需要容器运行时的机器 = K8s 节点 + 独立部署机
runtime_targets() {
    local t; t=$( { k8s_nodes; has_deploy_pseudo && echo "__deploy__"; [ "$HARBOR_INSTALL" = true ] && registry_node; } | awk '!seen[$0]++')
    echo "$t"
}
# 04b 步部署仓库的节点：harbor.node，留空 = 部署机
registry_node() {
    if [ -n "$HARBOR_NODE" ]; then echo "$HARBOR_NODE"
    elif [ -n "$(deploy_node)" ]; then deploy_node
    else echo "__deploy__"; fi
}
deploy_node() {   # 部署机对应的节点名（部署机不是节点时为空，不返回 __deploy__ 占位）
    local l n ip; for l in "${NODES[@]}"; do
        IFS='|' read -r n ip _ <<< "$l"
        [ "$n" = "__deploy__" ] && continue
        [ "$ip" = "$DEPLOY_HOST" ] && { echo "$n"; return; }
    done
}

# 离线包路径
pkg_arch_dir() { echo "$DEPLOY_PKG_DIR/$1"; }          # arch
# KubeKey 制品：migrate-pkg 整理的是 *.tar.gz；bundle 出的精简包是未压缩的 *.tar（外层整体 xz，压缩率更高）
artifact_file() { ls "$(pkg_arch_dir "$1")"/artifact/*.tar.gz "$(pkg_arch_dir "$1")"/artifact/*.tar 2>/dev/null | head -1; }
# OS 包文件名：os_pkg <os> deps|nfs|iscsi   与 2.1.2 包名保持一致
os_pkg() {
    local os=$1 kind=$2
    case "$kind:$os" in
        deps:centos) echo Centos.tar ;;     nfs:centos) echo Centosnfs.tar ;;     iscsi:centos) echo iscsi-centos7.tar ;;
        deps:kylin) echo Kylin.tar ;;       nfs:kylin) echo Kylinnfs.tar ;;       iscsi:kylin) echo iscsi-kylin.tar ;;
        deps:uos) echo Uos.tar ;;           nfs:uos) echo Uosnfs.tar ;;           iscsi:uos) echo iscsi-uos.tar ;;
        deps:ubuntu) echo Ubuntu.tar ;;     nfs:ubuntu) echo Ubuntunfs.tar ;;     iscsi:ubuntu) echo iscsi-ubuntu.tar ;;
        deps:openeuler) echo openEuler.tar ;; nfs:openeuler) echo Openeulernfs.tar ;; iscsi:openeuler) echo iscsi-openeuler.tar ;;
        deps:rockey) echo rockey.tar ;;     nfs:rockey) echo rockeynfs.tar ;;     iscsi:rockey) echo iscsi-rockey.tar ;;
        *) echo "" ;;
    esac
}
# tar 包内安装目录（包内自带 rpm.sh）
os_pkg_subdir() { case "$1" in deps) echo k8s-init ;; nfs) echo nfs ;; iscsi) echo iscsi ;; esac; }
os_pkg_path() { local f; f=$(os_pkg "$(node_os "$1")" "$2"); [ -n "$f" ] && echo "$(pkg_arch_dir "$(node_arch "$1")")/os/$f"; }

# 在节点上安装一个 OS 离线包（tar 内为 <subdir>/rpm.sh），带完成标记，可重复执行
MARK_DIR=/var/lib/k8s-deploy
install_os_pkg() {
    local n=$1 kind=$2 tarp sub
    if run_remote "$n" "[ -f $MARK_DIR/$kind.done ]" >/dev/null 2>&1; then
        log_info "[$n] $kind 离线包已安装，跳过"; return 0
    fi
    tarp=$(os_pkg_path "$n" "$kind")
    [ -n "$tarp" ] && [ -f "$tarp" ] || { log_error "[$n] 缺少 $kind 离线包: ${tarp:-<$(node_os "$n") 不支持>}"; return 1; }
    sub=$(os_pkg_subdir "$kind")
    log_info "[$n] 安装 $kind 离线包 $(basename "$tarp")"
    copy_to "$n" "$tarp" "$REMOTE_WORK/$(basename "$tarp")" || return 1
    run_remote "$n" "set -e
cd $REMOTE_WORK && rm -rf $sub && tar xf $(basename "$tarp")
cd $sub && bash rpm.sh > $REMOTE_WORK/$kind-install.log 2>&1 || { tail -20 $REMOTE_WORK/$kind-install.log; echo '[WARN] rpm.sh 返回非 0（已安装的包会报错，请看上方日志）'; }
mkdir -p $MARK_DIR && touch $MARK_DIR/$kind.done"
}

# kubectl apply 本地 yaml（kubectl 在远程 master 时自动拷贝过去）
kc_apply() {
    local f=$1
    [ -z "$KC_MODE" ] && init_kubectl
    if [ "$KC_MODE" = local ]; then
        kubectl apply -f "$f"
    else
        copy_to "${MASTERS[0]}" "$f" "$REMOTE_WORK/apply/$(basename "$f")" && \
            run_remote "${MASTERS[0]}" "kubectl apply -f $REMOTE_WORK/apply/$(basename "$f")"
    fi
}

wait_rollout() {   # ns kind name timeout
    kc -n "$1" rollout status "$2/$3" --timeout="${4:-600s}"
}

# 并行在多个节点执行函数：parallel_nodes <func> <node...>；任一失败返回 1
parallel_nodes() {
    local fn=$1; shift
    local pids=() names=() rc=0 i
    for n in "$@"; do
        "$fn" "$n" > "$LOG_DIR/.par-$n.log" 2>&1 &
        pids+=($!); names+=("$n")
    done
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            sed "s/^/[${names[$i]}] /" "$LOG_DIR/.par-${names[$i]}.log"
        else
            sed "s/^/[${names[$i]}] /" "$LOG_DIR/.par-${names[$i]}.log"; log_error "[${names[$i]}] 失败"; rc=1
        fi
        rm -f "$LOG_DIR/.par-${names[$i]}.log"
    done
    return $rc
}

# 仓库类型：harbor.type=auto 时，该架构有 Harbor 安装包（或 amd64 的 KubeKey 制品）→ harbor，否则 registry
resolve_registry_type() {
    local a=$1
    if [ "$HARBOR_TYPE" != auto ]; then echo "$HARBOR_TYPE"; return; fi
    if ls "$(pkg_arch_dir "$a")"/harbor/harbor-offline-installer-*.tgz >/dev/null 2>&1; then echo harbor
    elif [ "$a" = amd64 ] && [ ! -f "$(pkg_arch_dir "$a")/artifact/SLIM" ] && [ -n "$(artifact_file "$a")" ]; then echo harbor   # 完整 KubeKey 制品内带 Harbor
    else echo registry; fi
}
