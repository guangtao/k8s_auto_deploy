#!/usr/bin/env bash
# ============================================================
# 01 部署前检查（只读）
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 01-pre-check
require_root
check_ssh_tools
[ -f "$FACTS_FILE" ] || die "缺少节点探测结果，请先执行: bash deploy.sh facts"

FAIL=0; WARN=0; PASS=0
ok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

PORTS="6443 2379 2380 10250 10257 10259"
DEPLOY_ARCH=$(_detect_arch "$(uname -m)")

log_step "1. 离线包（部署机架构 $DEPLOY_ARCH）"
declare -A NEED_ARCH=()
for n in $(k8s_nodes); do NEED_ARCH[$(node_arch "$n")]=1; done
NEED_ARCH[$DEPLOY_ARCH]=1
for a in "${!NEED_ARCH[@]}"; do
    d=$(pkg_arch_dir "$a")
    [ -d "$d" ] || { fail "缺少 $d（可用 tools/migrate_pkg.sh 从 2.1.2 安装包整理）"; continue; }
    for f in docker/docker-24.0.9.tgz docker/docker-compose; do
        [ -f "$d/$f" ] && ok "$a/$f" || fail "缺少 $a/$f"
    done
    [ -n "$(artifact_file "$a")" ] && ok "$a/artifact" || fail "缺少 $a/artifact/*.tar[.gz]（KubeKey 制品）"
    n_img=$(find "$d/images" -name '*.tar' 2>/dev/null | wc -l)
    [ "$n_img" -gt 0 ] && ok "$a/images ($n_img 个)" || fail "$a/images 为空"
done
kkbin="$(pkg_arch_dir "$DEPLOY_ARCH")/kk"
[ -f "$kkbin" ] && [ ! -x "$kkbin" ] && chmod +x "$kkbin"          # 可执行位丢失（经 Windows 中转）时补上
if [ -x "$kkbin" ]; then ok "kk ($DEPLOY_ARCH)"
elif [ -f "$kkbin" ]; then fail "$kkbin 不可执行（chmod 失败，所在分区是否 noexec？）"
else fail "缺少 $kkbin"; fi
if [ -x "$kkbin" ]; then
    if strings "$kkbin" 2>/dev/null | grep -q "v$K8S_VERSION"; then ok "kk 支持 v$K8S_VERSION"; else warn "kk 中未找到 v$K8S_VERSION 版本信息，可能不支持"; fi
fi

log_step "2. 节点"
declare -A SEEN_HN=()
for n in $(k8s_nodes); do
    ip=$(node_ip "$n"); a=$(node_arch "$n"); os=$(node_os "$n")
    echo "  --- $n ($ip, $os/$a)"
    run_remote "$n" "true" >/dev/null 2>&1 || { fail "$n SSH 不通或无 root 权限"; continue; }
    case "$a" in amd64|arm64) ;; *) fail "$n 架构不支持: $a" ;; esac
    [ -n "$(os_pkg "$os" deps)" ] || fail "$n 系统 $os 不在支持列表"
    for k in deps iscsi nfs; do
        [ $k = iscsi ] && [ "$LONGHORN_ENABLED" != true ] && continue
        [ $k = nfs ] && [ "$NFS_ENABLED" != true ] && continue
        p=$(os_pkg_path "$n" $k)
        [ -n "$p" ] && [ -f "$p" ] && ok "$n $k 包 $(basename "$p")" || fail "$n 缺少 $k 包 ${p:-}"
    done

    info=$(run_remote "$n" "
        echo kernel=\$(uname -r)
        echo fw=\$(systemctl is-active firewalld 2>/dev/null; systemctl is-active ufw 2>/dev/null | sed 's/^/ufw-/')
        echo dns=\$(grep -c '^nameserver' /etc/resolv.conf 2>/dev/null)
        echo swap=\$(awk 'NR>1' /proc/swaps | wc -l)
        echo selinux=\$(getenforce 2>/dev/null)
        echo hostname=\$(hostname)
        echo mem=\$(awk '/MemTotal/{print int(\$2/1024/1024)}' /proc/meminfo)
        echo cpu=\$(nproc)
        echo free=\$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9)
        echo time=\$(date +%s)
        ports=''
        for p in $PORTS; do
            if (command -v ss >/dev/null && ss -tln | awk '{print \$4}' | grep -qE \":\$p\$\") || \
               (command -v netstat >/dev/null && netstat -tln | awk '{print \$4}' | grep -qE \":\$p\$\"); then ports=\"\$ports \$p\"; fi
        done
        echo ports=\$ports
        echo kubelet=\$(systemctl is-active kubelet 2>/dev/null)
    " 2>/dev/null)
    g() { sed -n "s/^$1=//p" <<< "$info"; }
    kern=$(g kernel); minv="3.10.0-1062"
    if [ "$(printf '%s\n%s\n' "$minv" "$kern" | sort -V | head -1)" = "$minv" ]; then ok "$n 内核 $kern"; else fail "$n 内核 $kern < $minv"; fi
    if [ "${kern%%.*}" = 3 ]; then
        [ "$KERNEL_UPGRADE" = true ] && [ "$os" = centos ] && [ "$a" = amd64 ] \
            && warn "$n 3.10 内核，将在 02 步升级 kernel-lt 并重启" \
            || warn "$n 3.10 内核，建议升级到 4.19+（Calico/Longhorn 稳定性）"
    fi
    if grep -qw active <<< "$(g fw)"; then fail "$n 防火墙运行中（$(g fw)），请关闭或放通端口"; else ok "$n 防火墙未运行"; fi
    [ "$(g dns)" -gt 0 ] 2>/dev/null && ok "$n resolv.conf 有 nameserver" || fail "$n /etc/resolv.conf 无 nameserver（CoreDNS 会异常）"
    [ "$(g swap)" -gt 0 ] 2>/dev/null && warn "$n 开启了 swap（kk 会关闭）"
    [ "$(g selinux)" = Enforcing ] && warn "$n SELinux Enforcing（kk 会设为 permissive）"
    hn=$(g hostname)
    [ "$hn" = localhost ] || [[ "$hn" == localhost.* ]] && warn "$n 主机名为 localhost（kk 会改为 $n）"
    [ -n "${SEEN_HN[$hn]:-}" ] && warn "$n 主机名 $hn 与 ${SEEN_HN[$hn]} 重复（kk 会改为节点名）"; SEEN_HN[$hn]=$n
    [ "$(g mem)" -lt 4 ] 2>/dev/null && warn "$n 内存 $(g mem)G < 4G"
    [ "$(g cpu)" -lt 2 ] 2>/dev/null && fail "$n CPU $(g cpu) 核 < 2"
    [ "$(g free)" -lt 20 ] 2>/dev/null && warn "$n /var/lib 可用 $(g free)G < 20G"
    dt=$(( $(g time) - $(date +%s) )); dt=${dt#-}
    [ "$dt" -gt 5 ] && warn "$n 与部署机时间相差 ${dt}s（kk 会配置 chrony 同步）"
    if [ -n "$(g ports | tr -d ' ')" ]; then
        if [ "$(g kubelet)" = active ]; then warn "$n 已在运行 kubelet（已是集群节点？）端口占用:$(g ports)"
        else fail "$n 端口被占用:$(g ports)"; fi
    else
        ok "$n K8s 端口空闲"
    fi
done

log_step "3. 网络 / 高可用"
if [ -n "$LB_VIP" ]; then
    if ping -c 1 -W 1 "$LB_VIP" >/dev/null 2>&1; then
        [ "$LB_MODE" = none ] && ok "外部 LB $LB_VIP 可达" || fail "VIP $LB_VIP 已被占用（ping 通）"
    else
        [ "$LB_MODE" = none ] && fail "外部 LB $LB_VIP 不可达" || ok "VIP $LB_VIP 未被占用"
    fi
fi
log_info "LB 模式: $LB_MODE   master 数: ${#MASTERS[@]}"
if [ "$LB_MODE" = keepalived ]; then
    for m in "${MASTERS[@]}"; do
        [ "$(node_arch "$m")" = arm64 ] && fail "master $m 为 arm64：keepalived 镜像(osixia/keepalived)没有 arm64 版本，请改用 lb.mode=kube-vip"
    done
fi

log_step "4. Harbor"
if [ "$HARBOR_INSTALL" = true ]; then
    RN=$(registry_node); RA=$(node_arch "$RN")
    RT=$(resolve_registry_type "$RA")
    log_info "harbor.install=True：04b 步在 $RN（$RA）部署 $RT"
    if curl -sk -o /dev/null --max-time 5 "$HARBOR_SCHEME://$HARBOR_REGISTRY/v2/"; then
        ok "$HARBOR_SCHEME://$HARBOR_REGISTRY 已有服务在运行（04b 会检查健康后跳过安装）"
    else
        hp=${HARBOR_REGISTRY##*:}; [ "$hp" = "$HARBOR_REGISTRY" ] && hp=""
        ports="${hp:-80 443}"
        busy=$(run_remote "$RN" "for p in $ports; do (ss -tln 2>/dev/null || netstat -tln) | awk '{print \$4}' | grep -qE \":\$p\$\" && echo \$p; done" 2>/dev/null | tr '\n' ' ')
        [ -z "$busy" ] && ok "$RN 端口 $ports 空闲" || fail "$RN 端口被占用: $busy（仓库需要）"
    fi
    hd="$(pkg_arch_dir "$RA")/harbor"
    if [ "$RT" = harbor ]; then
        if ls "$hd"/harbor-offline-installer-*.tgz >/dev/null 2>&1; then ok "Harbor 安装包: $(ls "$hd"/harbor-offline-installer-*.tgz | head -1 | xargs basename)"
        elif [ "$RA" = amd64 ] && [ ! -f "$(pkg_arch_dir amd64)/artifact/SLIM" ] && [ -n "$(artifact_file amd64)" ]; then ok "Harbor 安装包将从 KubeKey 制品中提取"
        else fail "缺少 $hd/harbor-offline-installer-*.tgz"; fi
    else
        [ -f "$hd/registry.tar" ] && ok "registry:2 镜像 $RA/harbor/registry.tar" || fail "缺少 $hd/registry.tar"
    fi
    [ "$HARBOR_SCHEME" = https ] && { command -v openssl >/dev/null && ok "openssl 可用（生成自签证书）" || fail "部署机缺少 openssl"; }
    # 仓库还没装，先确认各节点能连到仓库所在主机（以 SSH 22 端口探测）
    RIP=${HARBOR_REGISTRY%%:*}
    for n in $(k8s_nodes); do
        [ "$n" = "$RN" ] && continue
        if run_remote "$n" "timeout 3 bash -c '</dev/tcp/$RIP/22' 2>/dev/null || ping -c1 -W2 $RIP >/dev/null 2>&1" >/dev/null 2>&1; then
            ok "$n -> 仓库主机 $RIP 网络连通"
        else
            fail "$n 无法连到仓库主机 $RIP（Harbor 装好后节点也拉不到镜像；检查路由/防火墙）"
        fi
    done
else
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$HARBOR_SCHEME://$HARBOR_REGISTRY/v2/")
case "$code" in
    200|401) ok "Harbor $HARBOR_SCHEME://$HARBOR_REGISTRY 可访问 ($code)" ;;
    *) fail "Harbor $HARBOR_SCHEME://$HARBOR_REGISTRY 不可访问 (code=$code)"
       log_warn "当前 harbor.install=False，表示使用现场已有的 Harbor。现场没有 Harbor、需要本工具部署时："
       log_warn "  render_config.py 中设 harbor.install=True（harbor.node 留空 = 装在部署机，registry 填该机 IP），再执行 bash deploy.sh render && bash deploy.sh precheck"
       NO_HARBOR=1 ;;
esac
if [ -z "${NO_HARBOR:-}" ]; then
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -u "$HARBOR_USER:$HARBOR_PASSWD" "$HARBOR_SCHEME://$HARBOR_REGISTRY/api/v2.0/users/current")
[ "$code" = 200 ] && ok "Harbor 账号可登录" || warn "Harbor 账号校验返回 $code（非 Harbor 仓库可忽略）"
fi
for n in $(k8s_nodes); do
    [ -n "${NO_HARBOR:-}" ] && break
    c=$(run_remote "$n" "curl -sk -o /dev/null -w '%{http_code}' --max-time 5 $HARBOR_SCHEME://$HARBOR_REGISTRY/v2/" 2>/dev/null)
    [ "$c" = 200 ] || [ "$c" = 401 ] && ok "$n -> Harbor 连通" || fail "$n 无法访问 Harbor (code=$c)"
done
fi

if [ "$NFS_ENABLED" = true ]; then
    log_step "5. NFS"
    if [ -n "$NFS_SERVER_NODE" ]; then ok "NFS 服务器为节点 $NFS_SERVER_NODE，08 步自动配置"
    else
        ping -c 1 -W 1 "$NFS_SERVER" >/dev/null 2>&1 && ok "NFS $NFS_SERVER 可达" || fail "NFS $NFS_SERVER 不可达"
    fi
fi

log_step "汇总"
echo -e "  PASS=$PASS  ${YELLOW}WARN=$WARN${NC}  ${RED}FAIL=$FAIL${NC}"
[ $FAIL -eq 0 ] || die "预检未通过，请处理 FAIL 项"
state_set deploy_precheck_ok "$(date +%s)"
log_info "预检通过"
