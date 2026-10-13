#!/usr/bin/env bash
# ============================================================
# 03 重启需要生效新内核的节点（02 步记录）；没有则直接跳过
#   - 远程节点逐台重启。以 boot_id（每次开机都会变）判断是否真的重启过：
#     先等节点断开（或 boot_id 已变），再等它以新的 boot_id 恢复 SSH，最后校验内核
#   - 部署机所在节点最后重启。在一键部署（deploy.sh install）中，重启前注册一次性 systemd 服务
#     k8s-deploy-resume，开机后自动继续执行 install -y，执行一次后自删
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 03-reboot
require_root
check_ssh_tools

DOWN_TIMEOUT=${REBOOT_DOWN_TIMEOUT:-300}   # 等待节点开始关机（断开）的最长时间
UP_TIMEOUT=${REBOOT_UP_TIMEOUT:-900}       # 等待节点恢复的最长时间
RESUME_UNIT=k8s-deploy-resume.service

read -r -a NODES_TO_REBOOT <<< "$(state_get reboot_needed)"
if [ ${#NODES_TO_REBOOT[@]} -eq 0 ]; then
    log_info "没有需要重启的节点，跳过"
    exit 0
fi
confirm "将重启节点: ${NODES_TO_REBOOT[*]}，继续？" || exit 1

# 重启探测用更短的 SSH 超时：关机过程中的连接最多挂 10 秒，而不是默认的 3 分钟
for i in "${!SSH_OPTS[@]}"; do
    case "${SSH_OPTS[$i]}" in
        ConnectTimeout=*)      SSH_OPTS[$i]=ConnectTimeout=5 ;;
        ServerAliveInterval=*) SSH_OPTS[$i]=ServerAliveInterval=5 ;;
        ServerAliveCountMax=*) SSH_OPTS[$i]=ServerAliveCountMax=2 ;;
    esac
done
boot_id() { run_remote "$1" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]'; }

reboot_remote() {
    local n=$1 old_k old_b b t
    old_k=$(run_remote "$n" 'uname -r' 2>/dev/null)
    old_b=$(boot_id "$n")
    [ -n "$old_b" ] || die "[$n] 无法读取 boot_id（SSH 不通？）"
    log_info "[$n] 重启中（当前内核 $old_k）"
    run_remote "$n" "mkdir -p $MARK_DIR; touch $MARK_DIR/kernel.rebooted; nohup sh -c 'sleep 2; systemctl reboot' >/dev/null 2>&1 &" \
        || log_warn "[$n] 下发重启命令返回非 0（连接可能已被重启打断），继续观察"

    # 1) 等节点真正开始重启：SSH 断开，或者已经以新 boot_id 起来（重启极快时）
    t=0
    while :; do
        sleep 5; t=$((t + 5))
        b=$(boot_id "$n")
        [ -z "$b" ] && { log_info "[$n] 已断开，等待恢复"; break; }
        [ "$b" != "$old_b" ] && { log_info "[$n] 已完成重启"; break; }
        [ $t -ge "$DOWN_TIMEOUT" ] && die "[$n] ${DOWN_TIMEOUT}s 内没有开始重启（systemctl reboot 被阻塞？请登录检查）"
    done

    # 2) 等节点以新的 boot_id 恢复
    t=0
    until b=$(boot_id "$n") && [ -n "$b" ] && [ "$b" != "$old_b" ]; do
        [ $t -ge "$UP_TIMEOUT" ] && die "[$n] ${UP_TIMEOUT}s 内未恢复，请检查控制台（重启后重跑 deploy.sh install 即可继续）"
        sleep 10; t=$((t + 10))
    done
    # 刚恢复 SSH 时 systemd 可能仍在启动，等到 running/degraded
    for _ in $(seq 1 30); do
        s=$(run_remote "$n" 'systemctl is-system-running 2>/dev/null' 2>/dev/null)
        [[ "$s" == running || "$s" == degraded ]] && break
        sleep 5
    done
    new_k=$(run_remote "$n" 'uname -r' 2>/dev/null)
    if [ "$new_k" != "$old_k" ]; then log_info "[$n] 已恢复，内核 $new_k"
    else log_warn "[$n] 已重启，但内核未变化（$new_k），请检查 grub 默认启动项"; fi
}

SELF=""
for n in "${NODES_TO_REBOOT[@]}"; do
    if is_local_ip "$(node_ip "$n")"; then SELF=$n; continue; fi
    reboot_remote "$n"
    # 每台完成即更新待重启列表，中途失败重跑时不会重复重启已完成的节点
    left=(); for m in $(state_get reboot_needed); do [ "$m" = "$n" ] || left+=("$m"); done
    state_set reboot_needed "${left[*]}"
done

if [ -z "$SELF" ]; then
    log_info "重启完成"
    exit 0
fi

# ---------------- 部署机自身 ----------------
if [ "${K8S_DEPLOY_INSTALL:-}" = 1 ] && [[ "$ROOT_DIR" == *[[:space:]]* ]]; then
    log_warn "部署目录 $ROOT_DIR 含空格，无法注册自动续跑；部署机 $SELF 将在 10 秒后重启，重启后请执行: bash deploy.sh install"
elif [ "${K8S_DEPLOY_INSTALL:-}" = 1 ]; then
    resume_log="$LOG_DIR/install-resume-$(date +%Y%m%d-%H%M%S).log"
    if [ "${ASSUME_YES:-false}" = true ] || confirm "部署机 $SELF 需要重启。重启后是否自动继续部署（无人值守，等同 install -y）？"; then
        cat > "/etc/systemd/system/$RESUME_UNIT" <<EOF
[Unit]
Description=k8s-deploy: 重启后继续执行 deploy.sh install（一次性，执行后自删）
After=network-online.target sshd.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$ROOT_DIR
ExecStartPre=/bin/sh -c 'systemctl disable $RESUME_UNIT; rm -f /etc/systemd/system/$RESUME_UNIT'
ExecStart=/bin/bash -c 'sleep 20; exec bash $ROOT_DIR/deploy.sh install -y > $resume_log 2>&1'
TimeoutStartSec=0
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable "$RESUME_UNIT" >/dev/null 2>&1 \
            || die "注册自动续跑服务失败；可手动重启部署机后执行 bash deploy.sh install"
        log_warn "部署机 $SELF 将在 10 秒后重启；开机约 1 分钟后自动继续部署"
        log_warn "  查看进度: tail -f $resume_log"
        log_warn "  是否在跑: systemctl status $RESUME_UNIT"
    else
        log_warn "部署机 $SELF 将在 10 秒后重启；重启后请执行: cd $ROOT_DIR && bash deploy.sh install"
    fi
else
    log_warn "部署机 $SELF 将在 10 秒后重启；重启后继续执行后续步骤（如 bash deploy.sh runtime，或 bash deploy.sh install）"
fi
state_set reboot_needed ""
mkdir -p "$MARK_DIR" && touch "$MARK_DIR/kernel.rebooted"
sync
sleep 10
systemctl reboot
# 等待 systemd 结束本进程；返回非 0，避免 install 在关机过程中继续执行下一步
sleep 300
exit 1
