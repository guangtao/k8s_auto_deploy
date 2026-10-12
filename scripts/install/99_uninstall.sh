#!/usr/bin/env bash
# ============================================================
# 99 卸载集群（kk delete cluster）+ 清理 keepalived 与部署标记
#   不删除 docker/containerd、不删除 Longhorn/NFS 数据目录
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 99-uninstall
require_root
check_ssh_tools

KKCFG="$RENDERED/kk/cluster.yaml"
[ -f "$KKCFG" ] || python3 "$SCRIPTS_DIR/render_config.py" --kk || die "无法渲染 kk 配置"
[ -x "$WORK_DIR/kk" ] || die "缺少 $WORK_DIR/kk（集群不是由本工具创建？）"

log_warn "即将删除集群，所有工作负载与 etcd 数据将被清除！节点: $(k8s_nodes | tr '\n' ' ')"
read -r -p "请输入 DELETE 确认: " ans </dev/tty
[ "$ans" = DELETE ] || die "已取消"

cd "$WORK_DIR" || exit 1
./kk delete cluster -f "$KKCFG" --yes 2>&1 | tee -a "$LOG_DIR/kk-delete.log"

for m in "${MASTERS[@]}"; do
    run_remote "$m" "[ -f /etc/k8s-lb/docker-compose.yaml ] && cd /etc/k8s-lb && docker-compose down; rm -rf /etc/k8s-lb" >/dev/null 2>&1 || true
done
for n in $(k8s_nodes); do
    run_remote "$n" "rm -f $MARK_DIR/kernel.done; rm -rf /etc/kubernetes/upgrade-patches" >/dev/null 2>&1 || true
done
state_set k8s_installed ""
log_info "卸载完成（系统依赖包、容器运行时、存储数据目录保留）"
