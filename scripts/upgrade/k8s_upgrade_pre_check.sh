#!/usr/bin/env bash
# ============================================================
# 升级前检查：只读，不改动集群
#   FAIL 项必须处理后才能升级；WARN 项需人工确认
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log pre-check
require_root
check_ssh_tools

FAIL=0; WARN=0; PASS=0
ok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

TARGET_LAST=${UPGRADE_PATH[-1]}
TARGET_LAST_MINOR=$(ver_minor "$TARGET_LAST")

# ------------------------------------------------------------
log_step "1. 集群连通性与当前版本"
init_kubectl
if wait_apiserver 30; then ok "apiserver 可访问"; else fail "apiserver 不可访问"; fi

CUR=$(server_version)
[ -n "$CUR" ] || die "无法获取集群版本"
log_info "当前集群版本: $CUR   升级路径: ${UPGRADE_PATH[*]}"

prev=$CUR
for v in "${UPGRADE_PATH[@]}"; do
    if ver_ge "$prev" "$v"; then
        warn "目标 v$v 不高于当前/上一步 $prev，该步将被跳过"
        continue
    fi
    if [ $(( $(ver_minor "$v") - $(ver_minor "$prev") )) -gt 1 ]; then
        fail "$prev -> v$v 跨越超过 1 个小版本，kubeadm 不支持，请在 upgrade_path 中补齐中间版本"
    else
        ok "版本步进合法: $prev -> v$v"
    fi
    prev="v$v"
done

# 控制面版本一致性
for m in "${MASTERS[@]}"; do
    av=$(apiserver_version_on "$m")
    [ -z "$av" ] && { fail "未找到 kube-apiserver-$m（节点名需与 kubectl get nodes 一致）"; continue; }
    [ "$av" = "$CUR" ] || warn "$m 的 apiserver 版本 $av 与集群版本 $CUR 不一致（可能是上次升级中断）"
done

# ------------------------------------------------------------
log_step "2. 节点状态"
CLUSTER_NODES=$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for n in $(k8s_nodes); do
    if ! grep -qx "$n" <<< "$CLUSTER_NODES"; then
        fail "inventory 中的 $n 不在集群节点列表中"
        continue
    fi
    if node_ready "$n"; then ok "$n Ready (kubelet $(kubelet_version_of "$n"))"; else fail "$n NotReady"; fi
done
for n in $CLUSTER_NODES; do
    grep -qx "$n" <<< "$(k8s_nodes)" || warn "集群节点 $n 不在 inventory 中，将不会被升级"
done
unsched=$(kc get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name} {end}')
[ -n "$unsched" ] && warn "以下节点处于 cordon 状态: $unsched"

# ------------------------------------------------------------
log_step "3. 节点环境（SSH / 架构 / cgroup / containerd / 磁盘）"
declare -A ARCHES=()
for n in $(k8s_nodes); do
    if ! run_remote "$n" "true" >/dev/null 2>&1; then
        fail "$n SSH 不通或无 root 权限"
        continue
    fi
    arch=$(node_arch "$n")
    ARCHES[$arch]=1
    info=$(run_remote "$n" '
        echo "cgroup=$(stat -fc %T /sys/fs/cgroup/)"
        echo "containerd=$(containerd --version 2>/dev/null | awk "{print \$3}")"
        echo "varfree=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9)"
        echo "tmpfree=$(df -BG --output=avail /tmp 2>/dev/null | tail -1 | tr -dc 0-9)"
        f=/var/lib/kubelet/kubeadm-flags.env
        [ -f $f ] && echo "flags=$(cat $f | tr "\n" " ")"
        echo "kernel=$(uname -r)"
    ' 2>/dev/null)
    cg=$(sed -n 's/^cgroup=//p' <<< "$info")
    ctd=$(sed -n 's/^containerd=//p' <<< "$info"); ctd=${ctd#v}
    vfree=$(sed -n 's/^varfree=//p' <<< "$info")
    tfree=$(sed -n 's/^tmpfree=//p' <<< "$info")
    flags=$(sed -n 's/^flags=//p' <<< "$info")
    kern=$(sed -n 's/^kernel=//p' <<< "$info")
    log_info "$n: arch=$arch kernel=$kern cgroup=$cg containerd=${ctd:-none}"

    case "$arch" in amd64|arm64) ok "$n 架构 $arch" ;; *) fail "$n 架构不支持: $arch" ;; esac

    if [ "$cg" != "cgroup2fs" ]; then
        if [ "$TARGET_LAST_MINOR" -ge "$CGROUPV1_FAIL_FROM_MINOR" ]; then
            if [ "$ALLOW_CGROUP_V1" = "true" ]; then
                warn "$n 为 cgroup v1，目标 v$TARGET_LAST 默认拒绝启动 kubelet；已开启 allow_cgroup_v1，将下发 failCgroupV1=false 补丁"
            else
                fail "$n 为 cgroup v1，目标 v$TARGET_LAST 的 kubelet 默认拒绝启动；请切换 cgroup v2 或设置 allow_cgroup_v1=True"
            fi
        else
            warn "$n 为 cgroup v1（当前目标可用，但 1.$CGROUPV1_FAIL_FROM_MINOR 起需处理）"
        fi
    else
        ok "$n cgroup v2"
    fi

    if [ -z "$ctd" ]; then
        warn "$n 未检测到 containerd 版本"
    elif [ "${ctd%%.*}" -lt 2 ] 2>/dev/null; then
        if [ "$TARGET_LAST_MINOR" -gt "$CONTAINERD1_LAST_MINOR" ]; then
            fail "$n containerd $ctd：v$TARGET_LAST 不再支持 containerd 1.x，需先升级到 2.x"
        elif [ "$TARGET_LAST_MINOR" -eq "$CONTAINERD1_LAST_MINOR" ]; then
            warn "$n containerd $ctd：1.$CONTAINERD1_LAST_MINOR 是最后支持 containerd 1.x 的版本，后续需升级 containerd"
        else
            ok "$n containerd $ctd"
        fi
    else
        ok "$n containerd $ctd"
    fi

    [ -n "$vfree" ] && [ "$vfree" -lt "$MIN_FREE_GB" ] && fail "$n /var/lib 可用空间 ${vfree}G < ${MIN_FREE_GB}G"
    [ -n "$tfree" ] && [ "$tfree" -lt 2 ] && fail "$n /tmp 可用空间 ${tfree}G < 2G"

    for f in --pod-infra-container-image --network-plugin --container-runtime=; do
        [[ "$flags" == *"$f"* ]] && warn "$n kubeadm-flags.env 中含已废弃参数 $f，新版 kubelet 可能无法启动"
    done
done

# ------------------------------------------------------------
log_step "4. 离线升级包"
for v in "${UPGRADE_PATH[@]}"; do
    d=$(pkg_ver_dir "$v")
    if [ ! -f "$(pkg_images_list "$v")" ]; then
        fail "缺少 $d/images.list（请用 deploy.sh upgrade build 制作 v$v 升级包）"
        continue
    fi
    for a in "${!ARCHES[@]}"; do
        [[ "$a" == unknown* ]] && continue
        miss=""
        for b in kubeadm kubelet kubectl; do
            [ -x "$(pkg_bin "$v" "$a" "$b")" ] || miss+=" $b"
        done
        if [ -n "$miss" ]; then fail "v$v/$a 缺少二进制:$miss"; else ok "v$v/$a 二进制齐全"; fi
        n_img=$(find "$d/$a/images" -name '*.tar' 2>/dev/null | wc -l)
        [ "$n_img" -gt 0 ] && ok "v$v/$a 镜像包 $n_img 个" || fail "v$v/$a 无镜像包"
    done
    if [ -f "$d/sha256sums.txt" ]; then
        if (cd "$d" && sha256sum -c --quiet sha256sums.txt >/dev/null 2>&1); then
            ok "v$v sha256 校验通过"
        else
            fail "v$v sha256 校验失败，升级包可能损坏"
        fi
    else
        warn "v$v 无 sha256sums.txt，跳过完整性校验"
    fi
done

# ------------------------------------------------------------
log_step "5. 镜像仓库"
CREPO=$(cluster_image_repo)
REPO=$(image_repo)
log_info "kubeadm-config imageRepository=$CREPO  本工具推送地址=$REPO"
if [ -n "$CREPO" ] && [ "${CREPO%/}" != "$REPO" ]; then
    fail "镜像地址不一致：kubeadm 会从 $CREPO 拉取，请设置 upgrade.image_repository='$CREPO'"
else
    ok "镜像地址一致"
fi
if command -v docker >/dev/null 2>&1; then
    ins=(); [ "$REGISTRY_INSECURE" = "true" ] && ins=(--insecure)
    for v in "${UPGRADE_PATH[@]}"; do
        lst=$(pkg_images_list "$v"); [ -f "$lst" ] || continue
        missing=0
        while read -r img; do
            [ -z "$img" ] && continue
            docker manifest inspect "${ins[@]}" "$REPO/$img" >/dev/null 2>&1 || { missing=$((missing + 1)); log_warn "  仓库中暂无 $REPO/$img"; }
        done < "$lst"
        [ $missing -eq 0 ] && ok "v$v 所需镜像已在仓库中" || warn "v$v 有 $missing 个镜像尚未推送（升级前执行 deploy.sh upgrade push）"
    done
else
    warn "部署机无 docker，跳过仓库镜像检查"
fi

# ------------------------------------------------------------
log_step "6. etcd / 证书"
e=${ETCD_NODES[0]}
eh=$(run_remote "$e" "EP=https://$(node_ip "$e"):2379
$REMOTE_ETCD_CERTS
\$ETCDCTL endpoint health 2>&1" 2>&1)
if grep -q "is healthy" <<< "$eh"; then ok "etcd 健康 ($e)"; else fail "etcd 健康检查失败 ($e): $(head -2 <<< "$eh")"; fi

certs=$(run_remote "${MASTERS[0]}" "kubeadm certs check-expiration 2>/dev/null" 2>/dev/null)
if [ -n "$certs" ]; then
    expiring=$(awk '/[0-9]+d/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+d$/){d=$i; sub("d","",d); if(d+0<30) print $1}}' <<< "$certs" | sort -u | tr '\n' ' ')
    [ -n "$expiring" ] && warn "30 天内到期的证书: $expiring（kubeadm upgrade apply 会自动续期）" || ok "控制面证书剩余均 ≥30 天"
else
    warn "无法读取证书有效期"
fi

# ------------------------------------------------------------
log_step "7. 网络插件 / 存储 / 审计 / 驱逐阻塞"
cimg=$(kc -n kube-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
if [ -n "$cimg" ]; then
    cver=${cimg##*:}; cver=${cver#v}; cmm=${cver%.*}
    maxm=${CALICO_TESTED_MAX_MINOR[$cmm]:-}
    if [ -n "$maxm" ] && [ "$TARGET_LAST_MINOR" -gt "$maxm" ]; then
        warn "Calico $cver 官方测试上限约为 1.$maxm，目标 v$TARGET_LAST 超出范围，建议同步升级 Calico（本工具 v1 不包含）"
    else
        ok "Calico $cver"
    fi
fi

if kc get crd volumes.longhorn.io >/dev/null 2>&1; then
    bad=$(kc -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.robustness}/{.spec.numberOfReplicas}{"\n"}{end}' 2>/dev/null)
    unhealthy=$(grep -v -e '=healthy/' -e '=unknown/' -e '=/' <<< "$bad" | grep -c . || true)
    single=$(grep -c '/1$' <<< "$bad" || true)
    [ "$unhealthy" -gt 0 ] && warn "Longhorn 有 $unhealthy 个卷非 healthy，drain 可能卡住或造成数据不可用"
    [ "$single" -gt 0 ] && warn "Longhorn 有 $single 个单副本卷，drain 所在节点期间这些卷不可用（建议先调大副本或调整 node-drain-policy）"
    [ "$unhealthy" -eq 0 ] && [ "$single" -eq 0 ] && ok "Longhorn 卷均 healthy 且多副本"
fi

if [ "$AUDIT_ENABLED" = "true" ]; then
    for m in "${MASTERS[@]}"; do
        if run_remote "$m" "[ -f '$AUDIT_POLICY_FILE' ]" >/dev/null 2>&1; then
            ok "$m 审计策略文件存在"
        else
            warn "$m 无审计策略文件，升级时将自动下发"
        fi
    done
fi

pdb=$(kc get pdb -A -o jsonpath='{range .items[?(@.status.disruptionsAllowed==0)]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)
[ -n "$pdb" ] && warn "以下 PDB 当前不允许驱逐，drain 会阻塞: $pdb"

bp=$(kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded"{print $1"/"$2"("$4")"}' | head -20 | tr '\n' ' ')
[ -n "$bp" ] && warn "存在非 Running Pod（升级前建议处理）: $bp"

# ------------------------------------------------------------
log_step "汇总"
echo -e "  PASS=$PASS  ${YELLOW}WARN=$WARN${NC}  ${RED}FAIL=$FAIL${NC}"
if [ $FAIL -gt 0 ]; then
    log_error "预检未通过，请处理 FAIL 项后重试"
    exit 1
fi
state_set precheck_ok "$(date +%s)"
log_info "预检通过"
