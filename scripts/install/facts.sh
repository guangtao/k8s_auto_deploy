#!/usr/bin/env bash
# ============================================================
# 节点探测：架构 / 操作系统 / 内核 / cgroup / 主机名 / 网卡
# 输出 config/facts.sh（bash 使用）与 config/facts.json（渲染 kk 配置使用）
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
check_ssh_tools

declare -A FACT_ARCH=() FACT_OS=()
_ARCH_CACHE=(); _OS_CACHE=()
tmp_sh=$(mktemp); tmp_json=$(mktemp)
echo "# 自动生成 $(date '+%F %T')" > "$tmp_sh"
echo "declare -A FACT_ARCH FACT_OS FACT_KERNEL FACT_CGROUP FACT_HOSTNAME FACT_IFACE" >> "$tmp_sh"
echo "{" > "$tmp_json"
first=1; err=0

for n in $(runtime_targets); do
    ip=$(node_ip "$n")
    out=$(run_remote "$n" "uname -m
$REMOTE_DETECT_OS
uname -r
stat -fc %T /sys/fs/cgroup/
hostname
ip -o -4 addr show 2>/dev/null | awk -v ip=$ip '{split(\$4,a,\"/\"); if (a[1]==ip) print \$2}' | head -1" 2>/dev/null | tr -d '\r')
    if [ -z "$out" ]; then
        log_error "[$n] $ip 无法连接"; err=1; continue
    fi
    mapfile -t f <<< "$out"
    arch=$(_detect_arch "${f[0]}"); os=${f[1]}; kernel=${f[2]}
    cg=$([ "${f[3]}" = cgroup2fs ] && echo v2 || echo v1); hn=${f[4]}; iface=${f[5]:-}
    [ "$OS_TYPE" != auto ] && os=$OS_TYPE
    l=$(node_line "$n"); cfg_arch=${l##*|}
    if [ -n "$cfg_arch" ] && [ "$cfg_arch" != "$arch" ]; then
        log_warn "[$n] 配置 arch=$cfg_arch 与探测结果 $arch 不一致，以探测结果为准"
    fi
    printf '%-10s %-15s arch=%-6s os=%-10s kernel=%-28s cgroup=%s hostname=%s iface=%s\n' \
        "$n" "$ip" "$arch" "$os" "$kernel" "$cg" "$hn" "$iface"
    {
        echo "FACT_ARCH[$n]=$arch"; echo "FACT_OS[$n]=$os"; echo "FACT_KERNEL[$n]=$kernel"
        echo "FACT_CGROUP[$n]=$cg"; echo "FACT_HOSTNAME[$n]=$hn"; echo "FACT_IFACE[$n]=$iface"
    } >> "$tmp_sh"
    [ $first -eq 0 ] && echo "," >> "$tmp_json"; first=0
    printf '  "%s": {"ip": "%s", "arch": "%s", "os": "%s", "kernel": "%s", "cgroup": "%s", "hostname": "%s", "iface": "%s"}' \
        "$n" "$ip" "$arch" "$os" "$kernel" "$cg" "$hn" "$iface" >> "$tmp_json"
done
printf '\n}\n' >> "$tmp_json"

[ $err -eq 0 ] || { rm -f "$tmp_sh" "$tmp_json"; die "存在无法连接的节点，探测中止"; }
mv "$tmp_sh" "$ROOT_DIR/config/facts.sh"
mv "$tmp_json" "$ROOT_DIR/config/facts.json"
log_info "已写入 config/facts.sh 与 config/facts.json"
