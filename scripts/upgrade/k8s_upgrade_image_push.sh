#!/usr/bin/env bash
# ============================================================
# 升级：推送目标版本镜像到 Harbor（多架构 manifest list，与部署共用 lib/images.sh）
# 用法: bash k8s_upgrade_image_push.sh [版本...]   不带参数则推送 upgrade_path 中全部版本
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/images.sh
source "$(dirname "$0")/../lib/images.sh"
start_log upgrade-image-push
require_cmds docker curl

REPO=$(image_repo)
VERSIONS=("$@"); [ ${#VERSIONS[@]} -eq 0 ] && VERSIONS=("${UPGRADE_PATH[@]}")
declare -A NEED=()
for n in $(k8s_nodes); do NEED[$(node_arch "$n")]=1; done
log_info "目标仓库: $REPO   集群架构: ${!NEED[*]}"
docker_login_registry "$REPO"

FAILED=0
for v in "${VERSIONS[@]}"; do
    v=${v#v}
    d=$(pkg_ver_dir "$v"); lst=$(pkg_images_list "$v")
    [ -f "$lst" ] || die "缺少 $lst（先执行 deploy.sh upgrade build -v $v）"
    log_step "v$v"
    push_multiarch "$d" "$REPO" "${!NEED[@]}" || FAILED=1
    while read -r nt; do
        [ -z "$nt" ] && continue
        image_exists "$REPO/$nt" && log_info "  OK $nt" || { log_error "  仓库中不存在 $REPO/$nt"; FAILED=1; }
    done < "$lst"
done
[ $FAILED -eq 0 ] || die "镜像推送存在失败项"
state_set images_pushed "${VERSIONS[*]}"
log_info "升级镜像推送完成"
