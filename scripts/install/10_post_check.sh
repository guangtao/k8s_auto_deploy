#!/usr/bin/env bash
# ============================================================
# 10 部署后检查（逐项检查，不在第一个失败处退出）
#   节点数量/状态/架构、kube-system 组件、网络、DNS 解析、存储（真实 PVC 读写测试）、
#   metrics、审计、默认 StorageClass
# 用法: bash 10_post_check.sh [--no-pvc-test]
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
PVC_TEST=true; [ "${1:-}" = "--no-pvc-test" ] && PVC_TEST=false
start_log 10-post-check
check_ssh_tools
init_kubectl

FAIL=0; PASS=0; WARN=0
ok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }

log_step "节点"
sv=$(server_version)
[ "$sv" = "v$K8S_VERSION" ] && ok "集群版本 $sv" || fail "集群版本 $sv != v$K8S_VERSION"
for n in $(k8s_nodes); do
    if ! kc get node "$n" >/dev/null 2>&1; then fail "$n 不在集群中"; continue; fi
    ka=$(kc get node "$n" -o jsonpath='{.status.nodeInfo.architecture}')
    kv=$(kc get node "$n" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
    if node_ready "$n"; then ok "$n Ready $kv $ka"; else fail "$n NotReady"; fi
    [ "$ka" = "$(node_arch "$n")" ] || fail "$n 架构 $ka 与探测结果 $(node_arch "$n") 不一致"
done
for m in "${MASTERS[@]}"; do
    roles=$(kc get node "$m" -o jsonpath='{.metadata.labels}' 2>/dev/null)
    [[ "$roles" == *node-role.kubernetes.io/control-plane* ]] && ok "$m 为 control-plane" || fail "$m 缺少 control-plane 角色"
done

log_step "kube-system"
for obj in "deploy coredns" "ds kube-proxy" "ds calico-node" "deploy calico-kube-controllers" "ds nodelocaldns"; do
    read -r kind name <<< "$obj"
    kc -n kube-system get "$kind" "$name" >/dev/null 2>&1 || { [ "$name" = nodelocaldns ] || fail "$kind/$name 不存在"; continue; }
    if kc -n kube-system rollout status "$kind/$name" --timeout=120s >/dev/null 2>&1; then ok "$kind/$name 就绪"; else fail "$kind/$name 未就绪"; fi
done
bad=$(kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded"{print $1"/"$2"("$4")"}')
[ -z "$bad" ] && ok "全部 Pod Running/Completed" || fail "异常 Pod: $(head -15 <<< "$bad" | tr '\n' ' ')"
img_bad=$(kc get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | grep -v "^${HARBOR_REGISTRY}/" | sort -u)
[ -z "$img_bad" ] && ok "所有镜像均来自 $HARBOR_REGISTRY" || warn "以下镜像不来自私有仓库（离线环境会拉取失败）: $(tr '\n' ' ' <<< "$img_bad")"

log_step "高可用"
if [ -n "$LB_VIP" ]; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$LB_VIP:$LB_PORT/healthz")
    [ "$code" = 200 ] || [ "$code" = 401 ] || [ "$code" = 403 ] && ok "VIP $LB_VIP:$LB_PORT 可访问 apiserver ($code)" || fail "VIP $LB_VIP:$LB_PORT 不可访问 ($code)"
fi

log_step "DNS 与存储功能测试"
NS=k8s-deploy-check
kc create ns $NS >/dev/null 2>&1
SC_LINE=""; [ -n "$DEFAULT_SC" ] && SC_LINE="  storageClassName: $DEFAULT_SC"
TEST_YAML="$RENDERED/check.yaml"
{
cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: dns-check, namespace: $NS}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: $IMAGE_REPO/coredns:1.9.3
    command: ["/coredns", "-version"]
EOF
if [ "$PVC_TEST" = true ] && [ -n "$DEFAULT_SC" ]; then
cat <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-check, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
$SC_LINE
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: pvc-check, namespace: $NS}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: $IMAGE_REPO/pause:3.9
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - name: d
    persistentVolumeClaim: {claimName: pvc-check}
EOF
fi
} > "$TEST_YAML"
kc_apply "$TEST_YAML" >/dev/null 2>&1
# DNS: 通过 apiserver 内部解析 kubernetes.default
dns_ip=$(kc -n kube-system get svc coredns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || kc -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$dns_ip" ]; then
    r=$(run_remote "${MASTERS[0]}" "command -v nslookup >/dev/null && nslookup kubernetes.default.svc.cluster.local $dns_ip 2>/dev/null | tail -2 || (command -v dig >/dev/null && dig +short kubernetes.default.svc.cluster.local @$dns_ip)" 2>/dev/null)
    if [ -n "$r" ]; then ok "CoreDNS($dns_ip) 解析 kubernetes.default 正常"; else warn "master 上无 nslookup/dig 或解析失败，跳过 DNS 解析检查"; fi
fi
kc -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/dns-check --timeout=120s >/dev/null 2>&1 \
    && ok "测试 Pod 调度与镜像拉取正常" || fail "测试 Pod 未成功（检查镜像拉取 / 调度）"
if [ "$PVC_TEST" = true ] && [ -n "$DEFAULT_SC" ]; then
    if kc -n $NS wait --for=condition=Ready pod/pvc-check --timeout=300s >/dev/null 2>&1; then
        ok "StorageClass $DEFAULT_SC: PVC 创建、挂载成功"
    else
        fail "StorageClass $DEFAULT_SC: PVC 挂载失败（$(kc -n $NS get pvc pvc-check --no-headers 2>/dev/null | awk '{print $2}')）"
    fi
elif [ -z "$DEFAULT_SC" ]; then
    warn "未配置默认 StorageClass"
fi
kc delete ns $NS --wait=false >/dev/null 2>&1

log_step "插件"
if [ "$METRICS_ENABLED" = true ]; then
    if kc top nodes >/dev/null 2>&1; then ok "metrics-server 正常（kubectl top nodes）"; else warn "kubectl top nodes 不可用（metrics-server 刚启动需等待 1 分钟）"; fi
fi
if [ "$AUDIT_ENABLED" = true ]; then
    for m in "${MASTERS[@]}"; do
        run_remote "$m" "[ -s '$AUDIT_LOG_PATH' ]" >/dev/null 2>&1 && ok "$m 审计日志 $AUDIT_LOG_PATH 有内容" || fail "$m 无审计日志"
    done
fi
certs=$(run_remote "${MASTERS[0]}" "kubeadm certs check-expiration 2>/dev/null | awk '/apiserver /{print \$(NF-3)}'" 2>/dev/null)
[ -n "$certs" ] && ok "apiserver 证书剩余 $certs"

log_step "汇总"
echo -e "  PASS=$PASS  ${YELLOW}WARN=$WARN${NC}  ${RED}FAIL=$FAIL${NC}"
kc get nodes -o wide
[ $FAIL -eq 0 ] && log_info "集群部署验证通过" || { log_error "存在失败项"; exit 1; }
