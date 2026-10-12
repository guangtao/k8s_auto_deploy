#!/usr/bin/env bash
# ============================================================
# K8s 滚动升级（kubeadm 方式，x86 / ARM / 混合架构）
#
# 对 upgrade_path 中的每个版本依次执行：
#   1. 第一台 master : 换 kubeadm -> 预拉镜像 -> kubeadm upgrade apply
#   2. 其余 master   : 换 kubeadm -> kubeadm upgrade node（逐台，等待 apiserver 恢复）
#   3. 每台 master   : drain -> 换 kubelet/kubectl -> 重启 -> Ready -> uncordon
#   4. worker        : 按 worker_batch 分批 drain -> kubeadm upgrade node -> 换 kubelet -> uncordon
#
# 可重复执行：已到目标版本的控制面/节点会自动跳过（中断后直接重跑即可续升）
# etcd 由 KubeKey 以二进制方式管理，本工具不升级 etcd（--etcd-upgrade=false）
#
# 用法: bash k8s_upgrade.sh [-y] [--only-node <name>]
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

ONLY_NODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=true ;;
        --only-node) ONLY_NODE=$2; shift ;;
        *) die "未知参数: $1" ;;
    esac
    shift
done

start_log upgrade
require_root
check_ssh_tools
init_kubectl

REPO=$(image_repo)
TOTAL_NODES=$(k8s_nodes | wc -l)

# ---------------- 前置条件 ----------------
pre_gate() {
    local pc bk bt now
    now=$(date +%s)
    pc=$(state_get precheck_ok)
    if [ -z "$pc" ] || [ $((now - pc)) -gt 86400 ]; then
        log_warn "24 小时内没有通过的预检记录"
        confirm "仍然继续？（强烈建议先执行 deploy.sh upgrade precheck）" || exit 1
    fi
    bk=$(state_get last_backup); bt=$(state_get last_backup_time)
    if [ -z "$bk" ] || [ $((now - ${bt:-0})) -gt 86400 ]; then
        log_warn "24 小时内没有成功的备份记录"
        confirm "仍然继续？（强烈建议先执行 deploy.sh upgrade backup）" || exit 1
    else
        log_info "使用备份: $bk（升级前版本 $(state_get last_backup_version)）"
    fi
}

# ---------------- 节点操作 ----------------
drain_node() {
    local n=$1
    if [ "$DRAIN" != "true" ] || [ "$TOTAL_NODES" -le 1 ]; then
        log_info "[$n] 跳过 drain（drain=false 或单节点集群）"
        return 0
    fi
    log_info "[$n] cordon + drain (timeout $DRAIN_TIMEOUT)"
    # shellcheck disable=SC2086
    kc drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT" $DRAIN_EXTRA_ARGS || {
        log_error "[$n] drain 失败。常见原因：PDB 阻塞、Longhorn 单副本卷、裸 Pod。"
        log_error "      节点保持 cordon 状态，处理后重新执行本脚本即可继续"
        return 1
    }
}

uncordon_node() {
    local n=$1
    kc uncordon "$n" >/dev/null && log_info "[$n] uncordon"
}

# 下发 kubeadm（目标版本）
install_kubeadm() {
    local n=$1 v=$2 arch src
    arch=$(node_arch "$n")
    src=$(pkg_bin "$v" "$arch" kubeadm)
    [ -x "$src" ] || die "[$n] 缺少 $src"
    copy_to "$n" "$src" "$REMOTE_WORK/v$v/kubeadm" || die "[$n] kubeadm 传输失败"
    run_remote "$n" "$REMOTE_DETECT_BINS
install -m 0755 $REMOTE_WORK/v$v/kubeadm \$KUBEADM_BIN && \$KUBEADM_BIN version -o short" \
        || die "[$n] kubeadm 安装失败"
}

# 下发 kubelet / kubectl 并重启 kubelet
install_kubelet() {
    local n=$1 v=$2 arch
    arch=$(node_arch "$n")
    for b in kubelet kubectl; do
        copy_to "$n" "$(pkg_bin "$v" "$arch" $b)" "$REMOTE_WORK/v$v/$b" || die "[$n] $b 传输失败"
    done
    run_remote "$n" "$REMOTE_DETECT_BINS
set -e
systemctl stop kubelet
install -m 0755 $REMOTE_WORK/v$v/kubelet \$KUBELET_BIN
install -m 0755 $REMOTE_WORK/v$v/kubectl \$KUBECTL_BIN
systemctl daemon-reload
systemctl restart kubelet
\$KUBELET_BIN --version" || die "[$n] kubelet 安装/重启失败（可用 deploy.sh upgrade rollback --node $n 回滚）"
}

wait_node_version() {
    local n=$1 v=$2 i=0
    log_info "[$n] 等待 Ready 且 kubelet=v$v（超时 ${NODE_READY_TIMEOUT}s）"
    while [ $i -lt "$NODE_READY_TIMEOUT" ]; do
        if node_ready "$n" && [ "$(kubelet_version_of "$n")" = "v$v" ]; then
            log_info "[$n] Ready, kubelet v$v"
            return 0
        fi
        sleep 10; i=$((i + 10))
    done
    die "[$n] 超时未就绪，请检查: journalctl -u kubelet -n 100（在 $n 上）"
}

wait_cp_version() {
    local m=$1 v=$2 i=0
    while [ $i -lt 600 ]; do
        if [ "$(apiserver_version_on "$m")" = "v$v" ] && wait_apiserver 10; then
            local ready
            ready=$(kc -n kube-system get pod "kube-apiserver-$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            [ "$ready" = "True" ] && return 0
        fi
        sleep 10; i=$((i + 10))
    done
    die "[$m] 控制面 10 分钟内未切到 v$v"
}

# 审计策略文件 + patches 下发到 master
prepare_master() {   # stdout 只输出 --patches 参数，其余输出走 stderr
    local m=$1
    if [ "$AUDIT_ENABLED" = "true" ]; then {
        run_remote "$m" "[ -f '$AUDIT_POLICY_FILE' ]" >/dev/null 2>&1 \
            || copy_to "$m" "$ROOT_DIR/config/audit/audit-policy.yaml" "$AUDIT_POLICY_FILE" \
            || die "[$m] 审计策略下发失败"
        run_remote "$m" "mkdir -p \$(dirname '$AUDIT_LOG_PATH')"
    } >&2; fi
    sync_patches "$m"
}

prepull_images() {
    local n=$1 v=$2 filter=${3:-} lst imgs
    lst=$(pkg_images_list "$v")
    imgs=$(grep -E "${filter:-.}" "$lst" | sed "s#^#$REPO/#" | tr '\n' ' ')
    [ -z "$imgs" ] && return 0
    log_info "[$n] 预拉镜像: $(grep -cE "${filter:-.}" "$lst") 个"
    run_remote "$n" "rc=0; for i in $imgs; do crictl pull \$i >/dev/null 2>&1 || { echo \"pull failed: \$i\"; rc=1; }; done; exit \$rc" \
        || log_warn "[$n] 部分镜像预拉失败（kubeadm 会再次尝试拉取，若仍失败请检查仓库与 containerd certs.d 配置）"
}

# ---------------- 控制面 ----------------
upgrade_first_master() {
    local m=$1 v=$2 pflag ign=()
    if [ "$(apiserver_version_on "$m")" = "v$v" ]; then
        log_info "[$m] 控制面已是 v$v，跳过 upgrade apply"
        return 0
    fi
    log_step "[$m] kubeadm upgrade apply v$v"
    install_kubeadm "$m" "$v"
    pflag=$(prepare_master "$m") || die "[$m] patches 下发失败"
    prepull_images "$m" "$v"
    [ -n "$IGNORE_PREFLIGHT_ERRORS" ] && ign=(--ignore-preflight-errors="$IGNORE_PREFLIGHT_ERRORS")

    run_remote "$m" "\$(command -v kubeadm || echo /usr/local/bin/kubeadm) upgrade plan v$v ${ign[*]} 2>&1 | tail -40" || true
    confirm "确认在 $m 上执行 kubeadm upgrade apply v$v ？" || exit 1

    run_remote "$m" "\$(command -v kubeadm || echo /usr/local/bin/kubeadm) upgrade apply v$v -y \
        --etcd-upgrade=false --certificate-renewal=true $pflag ${ign[*]}" \
        || die "[$m] kubeadm upgrade apply 失败（kubeadm 已自动回滚静态 Pod 清单；查看上方输出定位原因）"
    wait_cp_version "$m" "$v"
    log_info "[$m] 控制面已升级到 v$v"
}

upgrade_other_master() {
    local m=$1 v=$2 pflag
    if [ "$(apiserver_version_on "$m")" = "v$v" ]; then
        log_info "[$m] 控制面已是 v$v，跳过 upgrade node"
        return 0
    fi
    log_step "[$m] kubeadm upgrade node（控制面）"
    install_kubeadm "$m" "$v"
    pflag=$(prepare_master "$m") || die "[$m] patches 下发失败"
    prepull_images "$m" "$v"
    run_remote "$m" "\$(command -v kubeadm || echo /usr/local/bin/kubeadm) upgrade node --certificate-renewal=true $pflag" \
        || die "[$m] kubeadm upgrade node 失败"
    wait_cp_version "$m" "$v"
    log_info "[$m] 控制面已升级到 v$v"
}

upgrade_node_kubelet() {
    local n=$1 v=$2 run_kubeadm=$3 pflag
    if [ "$(kubelet_version_of "$n")" = "v$v" ]; then
        log_info "[$n] kubelet 已是 v$v，跳过"
        uncordon_node "$n" >/dev/null 2>&1
        return 0
    fi
    log_step "[$n] 升级 kubelet -> v$v ($(node_arch "$n"))"
    drain_node "$n" || exit 1
    if [ "$run_kubeadm" = "yes" ]; then
        install_kubeadm "$n" "$v"
        pflag=$(sync_patches "$n") || die "[$n] patches 下发失败"
        prepull_images "$n" "$v" 'kube-proxy|pause'
        run_remote "$n" "\$(command -v kubeadm || echo /usr/local/bin/kubeadm) upgrade node $pflag" \
            || die "[$n] kubeadm upgrade node 失败"
    fi
    install_kubelet "$n" "$v"
    wait_node_version "$n" "$v"
    uncordon_node "$n"
}

# ---------------- 主流程 ----------------
main() {
    pre_gate
    log_info "节点: $(k8s_nodes | tr '\n' ' ')  架构: $(for n in $(k8s_nodes); do printf '%s=%s ' "$n" "$(node_arch "$n")"; done)"

    if [ -n "$ONLY_NODE" ]; then
        local v=${UPGRADE_PATH[-1]}
        log_warn "--only-node 模式：仅升级 $ONLY_NODE 的 kubelet 到 v$v（控制面需已完成）"
        upgrade_node_kubelet "$ONLY_NODE" "$v" "$(is_master "$ONLY_NODE" && echo no || echo yes)"
        return
    fi

    local v cur
    for v in "${UPGRADE_PATH[@]}"; do
        v=${v#v}
        cur=$(apiserver_version_on "${MASTERS[0]}")
        if ver_ge "$cur" "v$v" && [ "$cur" != "v$v" ]; then
            log_info "控制面 $cur 已高于 v$v，跳过该步"
            continue
        fi
        log_step "############ 升级到 v$v ############"
        confirm "开始升级到 v$v ？" || exit 1

        # 1-2. 控制面
        upgrade_first_master "${MASTERS[0]}" "$v"
        local i
        for ((i = 1; i < ${#MASTERS[@]}; i++)); do
            upgrade_other_master "${MASTERS[$i]}" "$v"
        done

        # 3. master 的 kubelet（kubeadm upgrade 已完成，不再执行 upgrade node）
        local m
        for m in "${MASTERS[@]}"; do
            upgrade_node_kubelet "$m" "$v" no
        done

        # 4. worker 分批
        local workers=() batch=() w
        mapfile -t workers < <(pure_workers)
        for ((i = 0; i < ${#workers[@]}; i += WORKER_BATCH)); do
            batch=("${workers[@]:i:WORKER_BATCH}")
            if [ ${#batch[@]} -eq 1 ]; then
                upgrade_node_kubelet "${batch[0]}" "$v" yes
            else
                log_step "worker 批次: ${batch[*]}"
                local pids=() rc=0
                for w in "${batch[@]}"; do
                    upgrade_node_kubelet "$w" "$v" yes > "$LOG_DIR/node-$w-v$v.log" 2>&1 &
                    pids+=($!)
                done
                for p in "${pids[@]}"; do wait "$p" || rc=1; done
                for w in "${batch[@]}"; do sed "s/^/[$w] /" "$LOG_DIR/node-$w-v$v.log"; done
                [ $rc -eq 0 ] || die "批次 ${batch[*]} 存在失败节点"
            fi
        done

        state_set upgraded_to "v$v"
        log_info "集群已升级到 v$v"
        kc get nodes -o wide
    done

    log_info "全部升级步骤完成，请执行 deploy.sh upgrade postcheck"
}

main
