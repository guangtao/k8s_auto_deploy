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
