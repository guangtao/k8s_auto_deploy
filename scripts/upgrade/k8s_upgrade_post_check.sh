#!/usr/bin/env bash
# ============================================================
# 升级后检查（逐项检查，不在第一个失败处退出）
# 用法: bash k8s_upgrade_post_check.sh [期望版本]   默认取 upgrade_path 最后一个
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log post-check
check_ssh_tools
init_kubectl

_w=${1:-${UPGRADE_PATH[-1]}}; WANT="v${_w#v}"
FAIL=0; PASS=0
ok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

log_step "期望版本 $WANT"
sv=$(server_version)
[ "$sv" = "$WANT" ] && ok "apiserver 版本 $sv" || fail "apiserver 版本 $sv != $WANT"

log_step "节点"
for n in $(k8s_nodes); do
    kv=$(kubelet_version_of "$n")
    if node_ready "$n" && [ "$kv" = "$WANT" ]; then
        ok "$n Ready kubelet=$kv arch=$(kc get node "$n" -o jsonpath='{.status.nodeInfo.architecture}')"
    else
        fail "$n ready=$(node_ready "$n" && echo yes || echo no) kubelet=$kv"
    fi
    [ "$(kc get node "$n" -o jsonpath='{.spec.unschedulable}')" = "true" ] && fail "$n 仍处于 cordon"
done

log_step "控制面组件"
for m in "${MASTERS[@]}"; do
    for c in kube-apiserver kube-controller-manager kube-scheduler; do
        p="$c-$m"
        img=$(kc -n kube-system get pod "$p" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
        rd=$(kc -n kube-system get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "${img##*:}" = "$WANT" ] && [ "$rd" = "True" ]; then ok "$p $WANT Ready"; else fail "$p image=${img##*:} ready=$rd"; fi
    done
done

log_step "Addons"
kp=$(kc -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
[ "${kp##*:}" = "$WANT" ] && ok "kube-proxy 镜像 $WANT" || fail "kube-proxy 镜像 ${kp##*:}"
for obj in "ds kube-proxy" "deploy coredns" "ds calico-node" "ds nodelocaldns"; do
    read -r kind name <<< "$obj"
    kc -n kube-system get "$kind" "$name" >/dev/null 2>&1 || continue
    if [ "$kind" = ds ]; then
        want=$(kc -n kube-system get ds "$name" -o jsonpath='{.status.desiredNumberScheduled}')
        have=$(kc -n kube-system get ds "$name" -o jsonpath='{.status.numberReady}')
    else
        want=$(kc -n kube-system get deploy "$name" -o jsonpath='{.spec.replicas}')
        have=$(kc -n kube-system get deploy "$name" -o jsonpath='{.status.readyReplicas}')
    fi
    [ "${have:-0}" = "$want" ] && ok "$kind/$name $have/$want" || fail "$kind/$name ${have:-0}/$want"
done

log_step "审计"
if [ "$AUDIT_ENABLED" = "true" ]; then
    for m in "${MASTERS[@]}"; do
        cmd=$(kc -n kube-system get pod "kube-apiserver-$m" -o jsonpath='{.spec.containers[0].command}' 2>/dev/null)
        [[ "$cmd" == *"--audit-policy-file"* ]] && ok "$m apiserver 已启用审计" || fail "$m apiserver 未找到审计参数"
        cnt=$(grep -o -- '--audit-policy-file' <<< "$cmd" | wc -l)
        [ "$cnt" -gt 1 ] && fail "$m 审计参数重复 $cnt 次"
    done
fi

log_step "工作负载"
bad=$(kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded"{print $1"/"$2"("$4")"}')
if [ -z "$bad" ]; then ok "所有 Pod Running/Completed"; else warn "非 Running Pod: $(head -20 <<< "$bad" | tr '\n' ' ')"; fi
if kc get crd volumes.longhorn.io >/dev/null 2>&1; then
    lb=$(kc -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.robustness}{"\n"}{end}' | grep -v -e '=healthy' -e '=unknown' | grep -c . || true)
    [ "$lb" -eq 0 ] && ok "Longhorn 卷正常" || warn "Longhorn 有 $lb 个卷非 healthy（重建副本中可稍后再查）"
fi

log_step "汇总"
echo -e "  PASS=$PASS  ${RED}FAIL=$FAIL${NC}"
[ $FAIL -eq 0 ] && log_info "升级后检查通过" || { log_error "升级后检查存在失败项"; exit 1; }
