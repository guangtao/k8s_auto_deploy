#!/usr/bin/env bash
# ============================================================
# 06 控制面 VIP（仅 lb.mode=keepalived）
#   每个 master 上以容器运行 keepalived（docker-compose，network_mode=host）
#   - 单播 VRRP（不依赖组播，适配云主机/虚拟化网络）
#   - 优先级 100/90/80...，检测本机 6443，apiserver 异常时降权漂移
#   - 网卡自动识别为节点 IP 所在网卡（可用 lb.interface 指定）
# kube-vip / haproxy 模式由 KubeKey 在 07 步内置部署，本步跳过
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 06-lb
require_root
check_ssh_tools

if [ "$LB_MODE" != keepalived ]; then
    log_info "lb.mode=$LB_MODE，本步跳过（kube-vip/haproxy 由 KubeKey 部署）"
    exit 0
fi
[ ${#MASTERS[@]} -ge 2 ] || log_warn "只有 1 个 master，keepalived 只提供固定 VIP，没有高可用效果"

OUT="$RENDERED/lb"; mkdir -p "$OUT"
idx=0
for m in "${MASTERS[@]}"; do
    ip=$(node_ip "$m")
    iface=${LB_INTERFACE:-${FACT_IFACE[$m]:-}}
    [ -z "$iface" ] && iface=$(run_remote "$m" "ip -o -4 addr show | awk -v ip=$ip '{split(\$4,a,\"/\"); if (a[1]==ip) print \$2}' | head -1")
    [ -n "$iface" ] || die "[$m] 无法识别 $ip 所在网卡，请设置 lb.interface"
    prio=$((100 - idx * 10)); idx=$((idx + 1))
    peers=""
    for p in "${MASTERS[@]}"; do [ "$p" = "$m" ] || peers+="        $(node_ip "$p")"$'\n'; done
    cat > "$OUT/keepalived-$m.conf" <<EOF
! 自动生成 —— k8s-deploy 06_lb.sh
global_defs {
    router_id k8s_$m
    script_user root
    enable_script_security
}

vrrp_script chk_apiserver {
    script "/bin/sh -c 'nc -z -w 2 127.0.0.1 $LB_PORT || wget -q -T 2 --no-check-certificate -O /dev/null https://127.0.0.1:$LB_PORT/healthz'"
    interval 3
    timeout 5
    fall 3
    rise 2
    weight -30
}

vrrp_instance VI_K8S {
    state BACKUP
    nopreempt
    interface $iface
    virtual_router_id $LB_VRID
    priority $prio
    advert_int 1
    unicast_src_ip $ip
    unicast_peer {
$peers    }
    authentication {
        auth_type PASS
        auth_pass k8s$(printf '%s' "$LB_VIP$LB_VRID" | md5sum | cut -c1-5)
    }
    virtual_ipaddress {
        $LB_VIP
    }
    track_script {
        chk_apiserver
    }
}
EOF
    log_info "[$m] iface=$iface priority=$prio"
done

cat > "$OUT/keepalived-compose.yaml" <<EOF
version: '3.8'
services:
  keepalived:
    image: $IMAGE_REPO/keepalived:latest
    container_name: k8s-keepalived
    restart: always
    network_mode: host
    cap_add: [NET_ADMIN, NET_BROADCAST, NET_RAW]
    volumes:
      - /etc/k8s-lb/keepalived.conf:/container/service/keepalived/assets/keepalived.conf:ro
    command: ["--copy-service"]
EOF

for m in "${MASTERS[@]}"; do
    log_step "[$m] 部署 keepalived"
    copy_to "$m" "$OUT/keepalived-$m.conf" /etc/k8s-lb/keepalived.conf || die "[$m] 下发失败"
    copy_to "$m" "$OUT/keepalived-compose.yaml" /etc/k8s-lb/docker-compose.yaml || die "[$m] 下发失败"
    run_remote "$m" "cd /etc/k8s-lb && docker-compose down >/dev/null 2>&1; docker-compose pull -q 2>/dev/null; docker-compose up -d" \
        || die "[$m] keepalived 启动失败"
done

log_info "等待 VIP $LB_VIP 生效"
for i in $(seq 1 30); do
    holder=""
    for m in "${MASTERS[@]}"; do
        run_remote "$m" "ip -o addr | grep -qw '$LB_VIP'" >/dev/null 2>&1 && holder+="$m "
    done
    if [ -n "$holder" ]; then
        log_info "VIP $LB_VIP 当前在: $holder"
        [ "$(wc -w <<< "$holder")" -gt 1 ] && log_warn "VIP 同时出现在多个节点（脑裂），请检查节点间 VRRP(协议 112) 是否被安全组拦截"
        exit 0
    fi
    sleep 2
done
die "60 秒内 VIP 未生效，查看日志: docker logs k8s-keepalived（在 master 上）"
