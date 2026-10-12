#!/usr/bin/env bash
# ============================================================
# 03 重启需要生效新内核的节点（02 步记录）；没有则直接跳过
#   远程节点先重启并等待恢复，部署机所在节点最后重启
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 03-reboot
require_root
check_ssh_tools

read -r -a NODES_TO_REBOOT <<< "$(state_get reboot_needed)"
if [ ${#NODES_TO_REBOOT[@]} -eq 0 ]; then
    log_info "没有需要重启的节点，跳过"
    exit 0
fi
confirm "将重启节点: ${NODES_TO_REBOOT[*]}，继续？" || exit 1

SELF=""
for n in "${NODES_TO_REBOOT[@]}"; do
    if is_local_ip "$(node_ip "$n")"; then SELF=$n; continue; fi
    old=$(run_remote "$n" 'uname -r')
    log_info "[$n] 重启中（当前内核 $old）"
    run_remote "$n" "mkdir -p $MARK_DIR; touch $MARK_DIR/kernel.rebooted; nohup sh -c 'sleep 2; systemctl reboot' >/dev/null 2>&1 &" || true
    sleep 20
    i=0
    until new=$(run_remote "$n" 'uname -r' 2>/dev/null) && [ -n "$new" ]; do
        i=$((i + 10)); [ $i -gt 900 ] && die "[$n] 15 分钟内未恢复"
        sleep 10
    done
    [ "$new" != "$old" ] && log_info "[$n] 已恢复，内核 $new" || log_warn "[$n] 已恢复，但内核未变化（$new），请检查 grub 默认项"
done

remaining=()
[ -n "$SELF" ] && remaining=("$SELF")
state_set reboot_needed "${remaining[*]}"
if [ -n "$SELF" ]; then
    log_warn "部署机所在节点 $SELF 需要重启，10 秒后重启；重启后重新执行 deploy.sh 继续后续步骤"
    state_set reboot_needed ""
    mkdir -p "$MARK_DIR" && touch "$MARK_DIR/kernel.rebooted"
    sleep 10
    systemctl reboot
fi
log_info "重启完成"
