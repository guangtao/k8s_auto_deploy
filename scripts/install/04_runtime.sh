#!/usr/bin/env bash
# ============================================================
# 04 容器运行时：docker 24.0.9（内含 containerd）+ docker-compose
#   - 按节点架构下发 pkg/<arch>/docker/
#   - containerd 使用 systemd cgroup，certs.d 配置 Harbor 与额外私有仓库
#   - 部署机不是集群节点时也会安装（推送镜像需要 docker）
# 节点并行，已安装且运行中的跳过（配置文件仍会更新并重启 containerd）
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 04-runtime
require_root
check_ssh_tools

CERTS_D="$RENDERED/runtime/certs.d"
build_certs_d() {
    rm -rf "$CERTS_D"; mkdir -p "$CERTS_D"
    local reg scheme host
    for reg in "$HARBOR_SCHEME://$HARBOR_REGISTRY" "${INSECURE_REGISTRIES[@]}"; do
        [ -z "$reg" ] && continue
        [[ "$reg" == *://* ]] || reg="http://$reg"
        scheme=${reg%%://*}; host=${reg#*://}
        mkdir -p "$CERTS_D/$host"
        cat > "$CERTS_D/$host/hosts.toml" <<EOF
server = "$scheme://$host"

[host."$scheme://$host"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
    done
    log_info "certs.d: $(ls "$CERTS_D" | tr '\n' ' ')"
}

install_runtime() {
    local n=$1 a d
    a=$(node_arch "$n"); d=$(pkg_arch_dir "$a")/docker
    [ -f "$d/docker-24.0.9.tgz" ] || { log_error "缺少 $d/docker-24.0.9.tgz"; return 1; }

    # 配置文件每次都下发（便于修改仓库配置后重跑）
    copy_to "$n" "$RENDERED/runtime" "$REMOTE_WORK/runtime" || return 1
    if run_remote "$n" "docker --version >/dev/null 2>&1 && systemctl is-active --quiet docker && systemctl is-active --quiet containerd"; then
        log_info "docker/containerd 已运行，仅更新 containerd 配置"
        run_remote "$n" "set -e
mkdir -p /etc/containerd/certs.d
cp -f $REMOTE_WORK/runtime/config.toml /etc/containerd/config.toml
cp -rf $REMOTE_WORK/runtime/certs.d/. /etc/containerd/certs.d/
systemctl restart containerd" || return 1
    else
        copy_to "$n" "$d/docker-24.0.9.tgz" "$REMOTE_WORK/docker-24.0.9.tgz" || return 1
        run_remote "$n" "set -e
cd $REMOTE_WORK
mkdir -p /etc/docker /etc/containerd/certs.d '$DOCKER_DATA_ROOT' '$CONTAINERD_DATA_ROOT'
tar xzf docker-24.0.9.tgz
cp -f docker/* /usr/bin/
cp -f runtime/docker.service /etc/systemd/system/docker.service
cp -f runtime/containerd.service /etc/systemd/system/containerd.service
cp -f runtime/daemon.json /etc/docker/daemon.json
cp -f runtime/config.toml /etc/containerd/config.toml
cp -rf runtime/certs.d/. /etc/containerd/certs.d/
systemctl daemon-reload
systemctl enable --now containerd
systemctl enable --now docker
sleep 3
systemctl is-active --quiet containerd
systemctl is-active --quiet docker
docker --version" || return 1
    fi
    if ! run_remote "$n" "docker-compose --version >/dev/null 2>&1"; then
        copy_to "$n" "$d/docker-compose" /usr/bin/docker-compose && run_remote "$n" "chmod +x /usr/bin/docker-compose" || return 1
    fi
    run_remote "$n" "docker-compose --version; containerd --version" | sed 's/^/  /'
}

build_certs_d
mapfile -t TARGETS < <(runtime_targets)
log_step "安装容器运行时: ${TARGETS[*]}"
parallel_nodes install_runtime "${TARGETS[@]}" || die "部分节点容器运行时安装失败"
log_info "容器运行时就绪"
