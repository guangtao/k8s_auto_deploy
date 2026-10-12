#!/usr/bin/env bash
# ============================================================
# 09 插件与加固
#   - metrics-server（多架构镜像，ARM 节点同样可用）
#   - apiserver 审计日志：幂等（已配置则跳过），逐台 master 修改并等待恢复，失败自动还原
#     同时把审计 patch 安装到 /etc/kubernetes/upgrade-patches，后续 kubeadm 升级不会丢失
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/images.sh
source "$(dirname "$0")/../lib/images.sh"
start_log 09-addons
require_root
check_ssh_tools
init_kubectl

# ---------------- metrics-server ----------------
if [ "$METRICS_ENABLED" = true ]; then
    log_step "metrics-server"
    if command -v docker >/dev/null && ! image_exists "$IMAGE_REPO/metrics-server:v0.7.2"; then
        log_warn "仓库中没有 metrics-server:v0.7.2，跳过（把镜像放入 pkg/<arch>/images 后重跑 05、09 步）"
    else
        kc_apply "$RENDERED/addons/metrics-server.yaml" >/dev/null || die "metrics-server apply 失败"
        # 混合集群：镜像只有一种架构时，限制调度到该架构节点，避免拉到不存在的架构
        if command -v docker >/dev/null; then
            ins=(); [ "$REGISTRY_INSECURE" = true ] && ins=(--insecure)
            img_arch=$(docker manifest inspect "${ins[@]}" "$IMAGE_REPO/metrics-server:v0.7.2" 2>/dev/null | grep -o '"architecture": *"[a-z0-9]*"' | sed 's/.*"\([a-z0-9]*\)"$/\1/' | sort -u)
            cl_arch=$(for n in $(k8s_nodes); do node_arch "$n"; done | sort -u)
            if [ "$(wc -l <<< "$img_arch")" -eq 1 ] && [ "$(wc -l <<< "$cl_arch")" -gt 1 ]; then
                kc -n kube-system patch deploy metrics-server --type merge \
                    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/arch\":\"$img_arch\"}}}}}" >/dev/null \
                    && log_warn "metrics-server 镜像只有 $img_arch，已限制调度到 $img_arch 节点"
            fi
        fi
        kc -n kube-system rollout status deploy/metrics-server --timeout=300s || log_warn "metrics-server 未就绪"
    fi
fi

# ---------------- 审计 ----------------
if [ "$AUDIT_ENABLED" = true ]; then
    log_step "apiserver 审计日志"
    pdir=$(dirname "$AUDIT_POLICY_FILE"); ldir=$(dirname "$AUDIT_LOG_PATH")
    for m in "${MASTERS[@]}"; do
        copy_to "$m" "$RENDERED/audit/audit-policy.yaml" "$AUDIT_POLICY_FILE" || die "[$m] 审计策略下发失败"
        sync_patches "$m" >/dev/null || die "[$m] patches 下发失败"
        if run_remote "$m" "grep -q -- '--audit-policy-file' /etc/kubernetes/manifests/kube-apiserver.yaml"; then
            log_info "[$m] 已启用审计，跳过"; continue
        fi
        log_info "[$m] 修改 kube-apiserver 静态 Pod"
        run_remote "$m" "set -e
F=/etc/kubernetes/manifests/kube-apiserver.yaml
mkdir -p '$ldir' /var/lib/k8s-deploy
cp -a \$F /var/lib/k8s-deploy/kube-apiserver.yaml.bak.\$(date +%Y%m%d%H%M%S)
cp -a \$F /tmp/kube-apiserver.yaml.new
N=/tmp/kube-apiserver.yaml.new
sed -i '/^    - kube-apiserver\$/a \\    - --audit-policy-file=$AUDIT_POLICY_FILE\\n    - --audit-log-path=$AUDIT_LOG_PATH\\n    - --audit-log-maxage=$AUDIT_MAXAGE\\n    - --audit-log-maxbackup=$AUDIT_MAXBACKUP\\n    - --audit-log-maxsize=$AUDIT_MAXSIZE\\n    - --audit-log-format=json\\n    - --audit-log-compress=true' \$N
sed -i '/^    volumeMounts:\$/a \\    - name: audit-policy\\n      mountPath: $pdir\\n      readOnly: true\\n    - name: audit-log\\n      mountPath: $ldir' \$N
sed -i '/^  volumes:\$/a \\  - name: audit-policy\\n    hostPath:\\n      path: $pdir\\n      type: Directory\\n  - name: audit-log\\n    hostPath:\\n      path: $ldir\\n      type: DirectoryOrCreate' \$N
[ \$(grep -c -- '--audit-policy-file' \$N) -eq 1 ] && [ \$(grep -c 'name: audit-log' \$N) -eq 2 ] || { echo '修改结果校验失败'; exit 1; }
# 原子替换，kubelet 检测到变更后重建 apiserver
mv \$N \$F" || die "[$m] 修改失败（原文件未变）"
        log_info "[$m] 等待 apiserver 重启"
        sleep 15
        ok=0
        for i in $(seq 1 36); do
            rd=$(kc -n kube-system get pod "kube-apiserver-$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            cmd=$(kc -n kube-system get pod "kube-apiserver-$m" -o jsonpath='{.spec.containers[0].command}' 2>/dev/null)
            if [ "$rd" = True ] && [[ "$cmd" == *audit-policy-file* ]]; then ok=1; break; fi
            sleep 5
        done
        if [ $ok -eq 1 ]; then
            log_info "[$m] 审计已生效: $AUDIT_LOG_PATH"
        else
            log_error "[$m] apiserver 3 分钟内未恢复，自动还原"
            run_remote "$m" "cp -a \$(ls -t /var/lib/k8s-deploy/kube-apiserver.yaml.bak.* | head -1) /etc/kubernetes/manifests/kube-apiserver.yaml"
            die "[$m] 审计配置失败，已还原；请检查 $AUDIT_POLICY_FILE 与 crictl logs"
        fi
    done
fi
state_set addons_done "$(date +%s)"
log_info "插件部署完成"
