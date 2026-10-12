#!/usr/bin/env bash
# ============================================================
# 05 推送部署镜像到 Harbor（多架构 manifest list）
#   pkg/<arch>/images/*.tar  ->  <harbor>/<project>/<name>:<tag>
#   KubeKey（namespaceOverride）、Longhorn、metrics-server、keepalived 等统一从该项目拉取
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/images.sh
source "$(dirname "$0")/../lib/images.sh"
start_log 05-image-push
require_root
require_cmds docker curl

declare -A NEED=()
for n in $(k8s_nodes); do NEED[$(node_arch "$n")]=1; done
log_info "目标仓库: $IMAGE_REPO   集群架构: ${!NEED[*]}"

ensure_harbor_project "$HARBOR_PROJECT"
docker_login_registry "$HARBOR_REGISTRY"
push_multiarch "$DEPLOY_PKG_DIR" "$IMAGE_REPO" "${!NEED[@]}" || die "镜像推送存在失败项（见上方 ERROR）"

# 关键镜像校验
log_step "关键镜像校验"
miss=0
for img in "pause:3.9" "kube-apiserver:v$K8S_VERSION" "kube-proxy:v$K8S_VERSION" "coredns:1.9.3"; do
    image_exists "$IMAGE_REPO/$img" && log_info "  OK $img" || { log_error "  缺少 $img"; miss=1; }
done
[ "$LONGHORN_ENABLED" = true ] && { image_exists "$IMAGE_REPO/longhorn-manager:v1.9.1" || { log_error "  缺少 longhorn-manager:v1.9.1"; miss=1; }; }
[ "$METRICS_ENABLED" = true ] && { image_exists "$IMAGE_REPO/metrics-server:v0.7.2" || log_warn "  缺少 metrics-server:v0.7.2（09 步将跳过 metrics-server）"; }
[ "$NFS_ENABLED" = true ] && { image_exists "$IMAGE_REPO/nfs-subdir-external-provisioner:v4.0.0" || { log_error "  缺少 nfs-subdir-external-provisioner:v4.0.0"; miss=1; }; }
[ "$LB_MODE" = keepalived ] && { image_exists "$IMAGE_REPO/keepalived:latest" || { log_error "  缺少 keepalived:latest"; miss=1; }; }
[ $miss -eq 0 ] || die "关键镜像缺失"
state_set images_pushed "$(date +%s)"
log_info "镜像推送完成"
