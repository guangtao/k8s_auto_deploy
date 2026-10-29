#!/usr/bin/env bash
# ============================================================
# 02 节点系统准备
#   - 按「节点系统 + 架构」安装 K8s 依赖离线包（conntrack/ipset/ipvsadm/socat/chrony/ebtables...）
#   - 可选：CentOS 7 x86 节点升级 kernel-lt 5.4（其它系统/架构自动跳过），需要 03 步重启
# 节点并行执行，可重复执行（完成标记 /var/lib/k8s-deploy/*.done）
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 02-os-prepare
require_root
check_ssh_tools

prepare_node() {
    local n=$1
    install_os_pkg "$n" deps || return 1
    # 内核模块与 sysctl（kk 也会设置，这里提前确保 br_netfilter 可用）
    run_remote "$n" 'modprobe br_netfilter 2>/dev/null; modprobe overlay 2>/dev/null
mkdir -p /etc/modules-load.d && printf "br_netfilter\noverlay\n" > /etc/modules-load.d/k8s-deploy.conf' || true
    # 防火墙、swap、SELinux：K8s 要求关闭（kk 也会处理一部分，这里统一提前做，保证幂等）
    #   firewalld: CentOS/RHEL/Rocky/openEuler/麒麟服务器版/UOS 服务器版   ufw: Ubuntu/Debian 系（含部分 UOS、麒麟桌面版）
    #   iptables/ip6tables（iptables-services）、nftables: 部分系统装了也会开机加载规则
    #   iptables/nftables 的 stop 会清空规则：集群已运行（kubelet active）时不动它们，避免清掉 kube-proxy/Calico 的规则
    run_remote "$n" 'units="firewalld ufw"
systemctl is-active -q kubelet 2>/dev/null || units="$units iptables ip6tables nftables"
for s in $units; do
    if systemctl is-active -q $s 2>/dev/null || systemctl is-enabled -q $s 2>/dev/null; then
        systemctl stop $s 2>/dev/null; systemctl disable $s 2>/dev/null; systemctl mask $s >/dev/null 2>&1; echo "  已关闭并禁用 $s"
    fi
done
command -v ufw >/dev/null 2>&1 && ufw disable >/dev/null 2>&1
# 麒麟 KYSEC：执行控制会拦截未签名的二进制（containerd、kubelet、calico 等），设为软模式（只记录不拦截）
if command -v getstatus >/dev/null 2>&1 && command -v setstatus >/dev/null 2>&1; then
    st=$(getstatus 2>/dev/null | grep -i "kysec status" | awk -F: "{print \$2}" | tr -d " ")
    if [ -n "$st" ] && [ "$st" != disable ] && [ "$st" != softmode ]; then
        setstatus softmode -p >/dev/null 2>&1 && echo "  麒麟 KYSEC 已设为 softmode" || echo "  [WARN] 麒麟 KYSEC 设置失败，请手动执行: setstatus softmode -p"
    fi
fi
if [ "$(awk "NR>1" /proc/swaps | wc -l)" -gt 0 ] || grep -qE "^[^#].*\sswap\s" /etc/fstab; then
    swapoff -a; sed -ri "s@^([^#].*\sswap\s.*)@#\1@" /etc/fstab; echo "  已关闭 swap（/etc/fstab 中已注释）"
fi
# 不在 fstab 里的 swap（systemd 的 .swap 单元、zram）开机仍会挂上：屏蔽它们
for u in $(systemctl list-units --type=swap --all --no-legend 2>/dev/null | awk "{print \$1}" | grep "\.swap$"); do
    systemctl mask "$u" >/dev/null 2>&1 && echo "  已屏蔽 $u"
done
systemctl is-enabled -q zramswap 2>/dev/null && { systemctl disable --now zramswap >/dev/null 2>&1; echo "  已关闭 zramswap"; }
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = Enforcing ]; then
    setenforce 0; echo "  SELinux 已设为 permissive"
fi
[ -f /etc/selinux/config ] && sed -ri "s/^SELINUX=enforcing/SELINUX=permissive/" /etc/selinux/config
true' | sed "s/^/[$n]/" || true
}

log_step "安装依赖离线包: $(k8s_nodes | tr '\n' ' ')"
mapfile -t ALL < <(k8s_nodes)
parallel_nodes prepare_node "${ALL[@]}" || die "部分节点依赖包安装失败"

# ---------------- 内核 ----------------
REBOOT=()
if [ "$KERNEL_UPGRADE" = true ]; then
    log_step "内核升级（仅 CentOS 7 / x86 / 3.10 内核）"
    KTAR="$(pkg_arch_dir amd64)/kernel/kernel.tar"
    for n in "${ALL[@]}"; do
        kern=$(run_remote "$n" 'uname -r' | tr -d '\r')   # 实时读取，facts 在重启后会过期
        if [ "$(node_os "$n")" != centos ] || [ "$(node_arch "$n")" != amd64 ] || [ "${kern%%.*}" != 3 ]; then
            log_info "[$n] $(node_os "$n")/$(node_arch "$n") 内核 $kern，无需升级"
            continue
        fi
        if run_remote "$n" "[ -f $MARK_DIR/kernel.rebooted ]" >/dev/null 2>&1; then
            log_warn "[$n] 已安装新内核并重启过，但仍是 $kern，请检查 grub 默认启动项（不再自动重启）"; continue
        fi
        if run_remote "$n" "[ -f $MARK_DIR/kernel.done ]" >/dev/null 2>&1; then
            log_info "[$n] 内核已安装，等待重启"; REBOOT+=("$n"); continue
        fi
        [ -f "$KTAR" ] || die "缺少 $KTAR"
        copy_to "$n" "$KTAR" "$REMOTE_WORK/kernel.tar" || die "[$n] 传输失败"
        run_remote "$n" "set -e
cd $REMOTE_WORK && rm -rf kernel && mkdir kernel && tar xf kernel.tar -C kernel && cd kernel
[ -f ke.tar ] && tar xf ke.tar && rpm -Uvh --force --nodeps ke/*.rpm >/dev/null 2>&1 || true
rpm -Uvh --force --nodeps kernel-lt-*.rpm
grub2-set-default 0 2>/dev/null || sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
[ -d /sys/firmware/efi ] && grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg >/dev/null 2>&1 || true
mkdir -p $MARK_DIR && touch $MARK_DIR/kernel.done" || die "[$n] 内核安装失败"
        log_info "[$n] kernel-lt 已安装"
        REBOOT+=("$n")
    done
fi
state_set reboot_needed "${REBOOT[*]}"
if [ ${#REBOOT[@]} -gt 0 ]; then
    log_warn "以下节点需要重启生效新内核: ${REBOOT[*]}（执行 deploy.sh 的 03 步）"
else
    log_info "无需重启"
fi
log_info "系统准备完成"
