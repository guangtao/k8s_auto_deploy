#!/usr/bin/env bash
# ============================================================
# 升级前备份
#   - etcd 快照（第一台 etcd 节点）
#   - 每个节点：/etc/kubernetes（含静态 Pod 清单、kube-vip、证书）、
#     kubelet 配置、kubeadm/kubelet/kubectl 二进制、kubelet systemd 单元
#   - 集群关键 ConfigMap / 节点与 Pod 快照
# 节点本地保留一份（回滚使用），部署机汇总一份
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log backup
require_root
check_ssh_tools
init_kubectl

TS=$(date +%Y%m%d-%H%M%S)
LOCAL_BK="$BACKUP_DIR/$TS"
mkdir -p "$LOCAL_BK/nodes" "$LOCAL_BK/cluster"
log_info "备份目录（部署机）: $LOCAL_BK"
log_info "备份目录（各节点）: $BACKUP_DIR/$TS"

ERR=0

# ---------------- etcd ----------------
if [ "$ETCD_BACKUP" = "true" ]; then
    log_step "etcd 快照"
    e=${ETCD_NODES[0]}
    if run_remote "$e" "EP=https://$(node_ip "$e"):2379
$REMOTE_ETCD_CERTS
mkdir -p '$BACKUP_DIR/$TS'
\$ETCDCTL snapshot save '$BACKUP_DIR/$TS/etcd-snapshot.db' && \
\$ETCDCTL --write-out=table snapshot status '$BACKUP_DIR/$TS/etcd-snapshot.db' 2>/dev/null || true
test -s '$BACKUP_DIR/$TS/etcd-snapshot.db'"; then
        copy_from "$e" "$BACKUP_DIR/$TS/etcd-snapshot.db" "$LOCAL_BK" \
            && log_info "etcd 快照已保存: $LOCAL_BK/etcd-snapshot.db" \
            || { log_error "etcd 快照回传失败"; ERR=1; }
    else
        log_error "etcd 快照失败"; ERR=1
    fi
fi

# ---------------- 节点文件 ----------------
for n in $(k8s_nodes); do
    log_step "备份节点 $n"
    if run_remote "$n" "$REMOTE_DETECT_BINS
set -e
B='$BACKUP_DIR/$TS'
mkdir -p \$B/bin
for b in \$KUBEADM_BIN \$KUBELET_BIN \$KUBECTL_BIN; do [ -f \$b ] && cp -a \$b \$B/bin/; done
echo \"KUBEADM_BIN=\$KUBEADM_BIN\"  > \$B/bin/paths.env
echo \"KUBELET_BIN=\$KUBELET_BIN\" >> \$B/bin/paths.env
echo \"KUBECTL_BIN=\$KUBECTL_BIN\" >> \$B/bin/paths.env
paths=''
for p in /etc/kubernetes /var/lib/kubelet/config.yaml /var/lib/kubelet/kubeadm-flags.env \
         /etc/systemd/system/kubelet.service /etc/systemd/system/kubelet.service.d \
         /usr/lib/systemd/system/kubelet.service /usr/lib/systemd/system/kubelet.service.d; do
    [ -e \$p ] && paths=\"\$paths \$p\"
done
tar czf \$B/node-files.tgz --absolute-names \$paths
\$KUBELET_BIN --version > \$B/kubelet.version 2>/dev/null || true
tar czf /tmp/k8s-upgrade-bk-$n.tgz -C \$B bin node-files.tgz kubelet.version
"; then
        copy_from "$n" "/tmp/k8s-upgrade-bk-$n.tgz" "$LOCAL_BK/nodes" \
            && run_remote "$n" "rm -f /tmp/k8s-upgrade-bk-$n.tgz" \
            && log_info "$n 备份完成" \
            || { log_error "$n 备份回传失败"; ERR=1; }
    else
        log_error "$n 备份失败"; ERR=1
    fi
done

# ---------------- 集群对象 ----------------
log_step "集群对象快照"
for cm in kubeadm-config kubelet-config kube-proxy coredns; do
    kc -n kube-system get cm "$cm" -o yaml > "$LOCAL_BK/cluster/cm-$cm.yaml" 2>/dev/null \
        || log_warn "ConfigMap $cm 不存在，跳过"
done
kc -n kube-system get deploy coredns -o yaml > "$LOCAL_BK/cluster/deploy-coredns.yaml" 2>/dev/null || true
kc -n kube-system get ds kube-proxy -o yaml  > "$LOCAL_BK/cluster/ds-kube-proxy.yaml" 2>/dev/null || true
kc get nodes -o wide          > "$LOCAL_BK/cluster/nodes.txt"
kc get pods -A -o wide        > "$LOCAL_BK/cluster/pods.txt"
kc get --raw /version         > "$LOCAL_BK/cluster/version.json"

if [ $ERR -ne 0 ]; then
    log_error "备份存在失败项，请检查后重试；本次不会被记为有效备份"
    exit 1
fi
state_set last_backup "$TS"
state_set last_backup_time "$(date +%s)"
state_set last_backup_version "$(server_version)"
du -sh "$LOCAL_BK" | awk '{print "备份大小: "$1}'
log_info "备份完成: $TS"
