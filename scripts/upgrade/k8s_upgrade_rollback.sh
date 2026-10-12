#!/usr/bin/env bash
# ============================================================
# 紧急回滚（节点级）
#   恢复节点上的 kubeadm/kubelet/kubectl 二进制、/etc/kubernetes（静态 Pod 清单）、
#   kubelet 配置，然后重启 kubelet。
#
# 说明：
#   - Kubernetes 官方不支持降级，本脚本用于“升级中途失败、尽快恢复服务”的场景，
#     优先用于单个失败节点（--node），整集群回滚请评估后进行。
#   - 不自动恢复 etcd。若确需恢复 etcd 快照，脚本末尾会打印操作步骤（会丢失快照后的所有变更）。
#
# 用法: bash k8s_upgrade_rollback.sh [--backup <时间戳>] [--node <name>]...
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log rollback
require_root
check_ssh_tools

TS=$(state_get last_backup)
TARGETS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --backup) TS=$2; shift ;;
        --node)   TARGETS+=("$2"); shift ;;
        -y)       ASSUME_YES=true ;;
        *) die "未知参数: $1" ;;
    esac
    shift
done
[ -n "$TS" ] || die "没有可用备份，请用 --backup 指定时间戳（$BACKUP_DIR 下的目录名）"
[ ${#TARGETS[@]} -eq 0 ] && mapfile -t TARGETS < <(k8s_nodes)

log_warn "即将使用备份 $TS 回滚节点: ${TARGETS[*]}"
log_warn "备份时集群版本: $(state_get last_backup_version)"
if [ "${ASSUME_YES:-false}" != "true" ]; then
    read -r -p "请输入 ROLLBACK 确认: " ans </dev/tty
    [ "$ans" = "ROLLBACK" ] || die "已取消"
fi

# master 优先，worker 在后
ordered=()
for n in "${TARGETS[@]}"; do is_master "$n" && ordered+=("$n"); done
for n in "${TARGETS[@]}"; do is_master "$n" || ordered+=("$n"); done

for n in "${ordered[@]}"; do
    log_step "回滚 $n"
    B="$BACKUP_DIR/$TS"
    if ! run_remote "$n" "[ -f $B/node-files.tgz ] && [ -f $B/bin/paths.env ]" >/dev/null 2>&1; then
        # 节点本地备份丢失时，从部署机下发
        [ -f "$BACKUP_DIR/$TS/nodes/k8s-upgrade-bk-$n.tgz" ] || { log_error "$n 无可用备份，跳过"; continue; }
        copy_to "$n" "$BACKUP_DIR/$TS/nodes/k8s-upgrade-bk-$n.tgz" "$B/restore.tgz" \
            && run_remote "$n" "cd $B && tar xzf restore.tgz" || { log_error "$n 备份下发失败"; continue; }
    fi
    if run_remote "$n" "
set -e
B=$B
source \$B/bin/paths.env
systemctl stop kubelet || true
cur=$BACKUP_DIR/rollback-before-\$(date +%Y%m%d-%H%M%S)
mkdir -p \$cur && tar czf \$cur/etc-kubernetes.tgz /etc/kubernetes 2>/dev/null || true
[ -f \$B/bin/kubeadm ] && install -m 0755 \$B/bin/kubeadm \$KUBEADM_BIN
[ -f \$B/bin/kubelet ] && install -m 0755 \$B/bin/kubelet \$KUBELET_BIN
[ -f \$B/bin/kubectl ] && install -m 0755 \$B/bin/kubectl \$KUBECTL_BIN
rm -rf /etc/kubernetes/manifests
tar xzf \$B/node-files.tgz --absolute-names
systemctl daemon-reload
systemctl restart kubelet
\$KUBELET_BIN --version
"; then
        log_info "$n 已恢复，等待 kubelet 上报"
    else
        log_error "$n 回滚失败，请登录节点手工处理"
    fi
done

sleep 20
init_kubectl 2>/dev/null && kc get nodes -o wide || log_warn "apiserver 暂不可访问，请稍后检查"

cat <<EOF

============================================================
若需恢复 etcd 快照（会丢失快照之后的全部集群变更，务必评估）：
  快照: $BACKUP_DIR/$TS/etcd-snapshot.db （部署机与 ${ETCD_NODES[0]} 各一份）
  1. 所有 master: mv /etc/kubernetes/manifests /etc/kubernetes/manifests.stop
  2. 所有 etcd 节点: systemctl stop etcd
  3. 每个 etcd 节点按自身 name/peer 地址执行 etcdutl snapshot restore（参照 /etc/etcd.env）
     并替换数据目录（默认 /var/lib/etcd）
  4. systemctl start etcd，确认 endpoint health
  5. 所有 master: mv /etc/kubernetes/manifests.stop /etc/kubernetes/manifests
============================================================
EOF
