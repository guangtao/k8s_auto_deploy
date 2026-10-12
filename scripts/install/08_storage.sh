#!/usr/bin/env bash
# ============================================================
# 08 存储
#   Longhorn: 各节点安装 iscsi 离线包并启用 iscsid -> 创建数据目录 -> apply longhorn.yaml -> 等待就绪
#   NFS     : 各节点安装 nfs 客户端离线包 -> (server_node 时) 配置 NFS 服务端 -> 部署 provisioner + StorageClass
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 08-storage
require_root
check_ssh_tools
init_kubectl
mapfile -t ALL < <(k8s_nodes)

if [ "$LONGHORN_ENABLED" != true ] && [ "$NFS_ENABLED" != true ]; then
    log_info "未启用任何存储，跳过"; exit 0
fi

# ---------------- Longhorn ----------------
longhorn_node() {
    local n=$1
    if run_remote "$n" "command -v iscsiadm >/dev/null 2>&1"; then
        log_info "iscsiadm 已存在"
    else
        install_os_pkg "$n" iscsi || return 1
    fi
    run_remote "$n" "set -e
systemctl enable --now iscsid >/dev/null 2>&1 || systemctl enable --now open-iscsi >/dev/null 2>&1 || true
modprobe iscsi_tcp 2>/dev/null || true
mkdir -p '$LONGHORN_DATA_PATH'
command -v iscsiadm >/dev/null && echo 'iscsi ready'"
}

if [ "$LONGHORN_ENABLED" = true ]; then
    log_step "Longhorn 节点准备"
    parallel_nodes longhorn_node "${ALL[@]}" || die "iscsi 准备失败"
    log_step "部署 Longhorn"
    kc_apply "$RENDERED/storage/longhorn.yaml" >/dev/null || die "longhorn.yaml apply 失败"
    log_info "等待 longhorn-manager / csi 就绪（最长 15 分钟）"
    kc -n longhorn-system rollout status ds/longhorn-manager --timeout=900s || die "longhorn-manager 未就绪"
    for i in $(seq 1 60); do
        kc get sc longhorn >/dev/null 2>&1 && kc -n longhorn-system get deploy csi-provisioner >/dev/null 2>&1 && break
        sleep 10
    done
    kc -n longhorn-system rollout status deploy/csi-provisioner --timeout=600s || log_warn "csi-provisioner 未就绪，请检查 longhorn-system"
    kc get sc
fi

# ---------------- NFS ----------------
if [ "$NFS_ENABLED" = true ]; then
    log_step "NFS 客户端"
    nfs_node() { install_os_pkg "$1" nfs; }
    targets=("${ALL[@]}")
    if [ -n "$NFS_SERVER_NODE" ] && ! printf '%s\n' "${ALL[@]}" | grep -qx "$NFS_SERVER_NODE"; then targets+=("$NFS_SERVER_NODE"); fi
    parallel_nodes nfs_node "${targets[@]}" || die "nfs 包安装失败"

    if [ -n "$NFS_SERVER_NODE" ]; then
        log_step "配置 NFS 服务端 $NFS_SERVER_NODE:$NFS_PATH"
        run_remote "$NFS_SERVER_NODE" "set -e
mkdir -p '$NFS_PATH'
grep -qE '^${NFS_PATH}[[:space:]]' /etc/exports 2>/dev/null || echo '$NFS_PATH *(rw,sync,no_root_squash,no_subtree_check)' >> /etc/exports
systemctl enable --now rpcbind >/dev/null 2>&1 || true
systemctl enable --now nfs-server >/dev/null 2>&1 || systemctl enable --now nfs >/dev/null 2>&1 || systemctl enable --now nfs-kernel-server
exportfs -ra
exportfs -v | grep '$NFS_PATH'" || die "NFS 服务端配置失败"
    fi
    for n in "${ALL[@]}"; do
        run_remote "$n" "showmount -e $NFS_SERVER 2>/dev/null | grep -q '$NFS_PATH'" >/dev/null 2>&1 \
            && log_info "[$n] 可见 $NFS_SERVER:$NFS_PATH" || log_warn "[$n] showmount 未看到 $NFS_SERVER:$NFS_PATH"
    done
    log_step "部署 nfs provisioner"
    kc_apply "$RENDERED/storage/nfs-provisioner.yaml" || die "nfs-provisioner apply 失败"
    kc -n "$NFS_NAMESPACE" rollout status deploy/nfs-client-provisioner --timeout=300s || die "nfs-client-provisioner 未就绪"
fi

# 只保留一个默认 StorageClass（KubeKey 可能自带 local）
if [ -n "$DEFAULT_SC" ]; then
    for sc in $(kc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        [ "$sc" = "$DEFAULT_SC" ] && continue
        kc patch sc "$sc" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1
    done
    kc patch sc "$DEFAULT_SC" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
    log_info "默认 StorageClass: $DEFAULT_SC"
fi
state_set storage_done "$(date +%s)"
log_info "存储部署完成"
