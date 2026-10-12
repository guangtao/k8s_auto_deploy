#!/usr/bin/env bash
# ============================================================
# 07 使用 KubeKey 创建集群（离线）
#   - 按探测到的节点架构渲染 kk 配置（每个 host 带 arch）
#   - 集群中有几种架构就解压几份 artifact 到同一个 kubekey 目录（路径中带 arch，互不覆盖）
#   - 使用部署机架构对应的 kk 二进制
#   - 已存在且节点齐全的集群自动跳过（--force 强制重跑 kk create）
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
FORCE=false
for a in "$@"; do case "$a" in --force) FORCE=true ;; -y) ASSUME_YES=true ;; esac; done
start_log 07-k8s-install
require_root
check_ssh_tools

cluster_complete() {
    command -v kubectl >/dev/null 2>&1 || return 1
    timeout 10 kubectl get --raw /readyz >/dev/null 2>&1 || return 1
    local n have
    have=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    for n in $(k8s_nodes); do grep -qx "$n" <<< "$have" || return 1; done
}

if [ "$FORCE" != true ] && cluster_complete; then
    log_info "集群已存在且节点齐全，跳过 kk create（如需重跑请加 --force）"
    kubectl get nodes -o wide
    exit 0
fi

# ---------------- 渲染 kk 配置 ----------------
log_step "渲染 KubeKey 配置"
python3 "$SCRIPTS_DIR/render_config.py" --kk || die "kk 配置渲染失败"
KKCFG="$RENDERED/kk/cluster.yaml"
grep -E '^\s+- \{name:' "$KKCFG" | sed -E 's/password: [^,}]*/password: ******/' | sed 's/^/  /'

# ---------------- 准备 kk 工作目录 ----------------
DEPLOY_ARCH=$(_detect_arch "$(uname -m)")
mkdir -p "$WORK_DIR/kubekey"
install -m 0755 "$(pkg_arch_dir "$DEPLOY_ARCH")/kk" "$WORK_DIR/kk" || die "缺少 $(pkg_arch_dir "$DEPLOY_ARCH")/kk"

declare -A NEED=()
for n in $(k8s_nodes); do NEED[$(node_arch "$n")]=1; done
for a in "${!NEED[@]}"; do
    if [ -f "$WORK_DIR/.artifact-$a.done" ]; then
        log_info "artifact($a) 已解压"; continue
    fi
    art=$(artifact_file "$a")
    [ -n "$art" ] || die "缺少 $(pkg_arch_dir "$a")/artifact/*.tar[.gz]"
    log_info "解压 artifact($a): $(basename "$art")（较大，请稍候）"
    tar xf "$art" -C "$WORK_DIR/kubekey" || die "解压失败: $art"
    [ -x "$WORK_DIR/kubekey/kube/v$K8S_VERSION/$a/kubeadm" ] \
        || die "artifact($a) 中没有 kube/v$K8S_VERSION/$a/kubeadm，请确认 kubernetes.version 与制品一致"
    touch "$WORK_DIR/.artifact-$a.done"
done

# ---------------- 创建集群 ----------------
log_step "kk create cluster（v$K8S_VERSION, LB=$LB_MODE）"
confirm "开始创建集群？" || exit 1
cd "$WORK_DIR" || die "无法进入 $WORK_DIR"
./kk create cluster -f "$KKCFG" --yes 2>&1 | tee -a "$LOG_DIR/kk-create.log"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "kk create cluster 失败（rc=$rc），详见 $LOG_DIR/kk-create.log；修复后可直接重跑本步"

# ---------------- 部署机 kubectl ----------------
if ! is_master "$(deploy_node)"; then
    log_info "部署机不是 master，拷贝 kubeconfig 与 kubectl"
    copy_from "${MASTERS[0]}" /root/.kube/config "$WORK_DIR/kubeconfig" || die "获取 kubeconfig 失败"
    mkdir -p /root/.kube && install -m 0600 "$WORK_DIR/kubeconfig/config" /root/.kube/config
    install -m 0755 "$WORK_DIR/kubekey/kube/v$K8S_VERSION/$DEPLOY_ARCH/kubectl" /usr/local/bin/kubectl
    # kubeconfig 中 server 为 lb.kubesphere.local，独立部署机需要 hosts 解析
    if [ -z "$(deploy_node)" ] || ! grep -q 'lb.kubesphere.local' /etc/hosts; then
        ep=${LB_VIP:-$(node_ip "${MASTERS[0]}")}
        sed -i '/lb\.kubesphere\.local/d' /etc/hosts
        echo "$ep  lb.kubesphere.local" >> /etc/hosts
        log_info "/etc/hosts: $ep lb.kubesphere.local"
    fi
fi

init_kubectl
log_info "等待节点 Ready"
for i in $(seq 1 60); do
    nr=0
    for n in $(k8s_nodes); do node_ready "$n" || nr=$((nr + 1)); done
    [ $nr -eq 0 ] && break
    sleep 10
done
kc get nodes -o wide
[ $nr -eq 0 ] || die "$nr 个节点 10 分钟内未 Ready"
state_set k8s_installed "$(date +%s)"
log_info "集群创建完成"
