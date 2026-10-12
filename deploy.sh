#!/usr/bin/env bash
# ============================================================
# k8s-deploy —— K8s 集群离线自动化部署 / 升级（x86_64 / aarch64 / 混合架构）
#
#   bash deploy.sh                 交互菜单
#   bash deploy.sh install [-y]    一键部署（00 → 10，按需重启）
#   bash deploy.sh <步骤> [参数]    单步执行，见 usage
#   bash deploy.sh upgrade ...     升级子命令
# ============================================================
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
S="$ROOT_DIR/scripts"
I="$S/install"
U="$S/upgrade"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

usage() {
cat <<'EOF'
用法: bash deploy.sh <命令> [参数]

部署:
  bootstrap   00 部署机初始化（python3/jinja2/sshpass 离线安装）
  render         渲染配置（修改 scripts/render_config.py 后执行）
  facts          探测节点架构/系统/内核
  precheck    01 部署前检查
  os          02 系统依赖包（+ 可选内核升级）
  reboot      03 重启需要的节点
  runtime     04 docker / containerd
  images      05 推送多架构镜像到 Harbor
  lb          06 keepalived VIP（仅 lb.mode=keepalived）
  k8s         07 KubeKey 创建集群   [--force]
  storage     08 Longhorn / NFS
  addons      09 metrics-server / 审计
  postcheck   10 部署后检查        [--no-pvc-test]
  install        一键执行全部部署步骤   [-y]
  uninstall   99 卸载集群

升级:
  upgrade build -v 1.34.2 ...      制作离线升级包（联网机器）
  upgrade push|precheck|backup|run|postcheck|rollback
  upgrade all [-y]                 推镜像 → 预检 → 备份 → 升级 → 后检

离线包:
  migrate-pkg --x86 <2.1.2 x86 目录> --arm <2.1.2 arm 目录>   整理离线包到 pkg/{amd64,arm64}（默认硬链接）
  verify-pkg [amd64|arm64]       校验离线包架构、完整性、必需镜像是否齐全
  fetch-images [--plan] [-a amd64,arm64] [-f 清单]   按清单只下载缺的镜像（默认 images/images-v1.33.4.txt）
  bundle [-a amd64,arm64] [--with-upgrade]                    出包：代码 + 离线包打成一个 tar.gz
EOF
}

run() {
    local s=$1; shift
    bash "$s" "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo -e "${RED}[ERROR] $(basename "$s") 失败 (rc=$rc)，流程中止。修复后可单独重跑该步骤，已完成的步骤会自动跳过。${NC}"
        exit $rc
    fi
}

ensure_render() {
    if [ ! -f "$ROOT_DIR/config/inventory.sh" ] || [ "$S/render_config.py" -nt "$ROOT_DIR/config/inventory.sh" ]; then
        python3 -c 'import jinja2' 2>/dev/null || run "$I/00_bootstrap.sh"
        echo "[INFO] 渲染配置"
        python3 "$S/render_config.py" || exit 1
    fi
}
ensure_facts() {
    ensure_render
    if [ ! -f "$ROOT_DIR/config/facts.sh" ] || [ "$ROOT_DIR/config/inventory.sh" -nt "$ROOT_DIR/config/facts.sh" ]; then
        run "$I/facts.sh"
    fi
}

cmd=${1:-menu}; shift 2>/dev/null
case "$cmd" in
    -h|--help|help) usage ;;
    bootstrap) run "$I/00_bootstrap.sh" ;;
    render)    python3 -c 'import jinja2' 2>/dev/null || run "$I/00_bootstrap.sh"; python3 "$S/render_config.py" ;;
    facts)     ensure_render; run "$I/facts.sh" ;;
    precheck)  ensure_facts; run "$I/01_pre_check.sh" "$@" ;;
    os)        ensure_facts; run "$I/02_os_prepare.sh" "$@" ;;
    reboot)    ensure_facts; run "$I/03_reboot.sh" "$@" ;;
    runtime)   ensure_facts; run "$I/04_runtime.sh" "$@" ;;
    images)    ensure_facts; run "$I/05_image_push.sh" "$@" ;;
    lb)        ensure_facts; run "$I/06_lb.sh" "$@" ;;
    k8s)       ensure_facts; run "$I/07_k8s_install.sh" "$@" ;;
    storage)   ensure_facts; run "$I/08_storage.sh" "$@" ;;
    addons)    ensure_facts; run "$I/09_addons.sh" "$@" ;;
    postcheck) ensure_facts; run "$I/10_post_check.sh" "$@" ;;
    uninstall) ensure_facts; run "$I/99_uninstall.sh" "$@" ;;
    install)
        [ "${1:-}" = "-y" ] && export ASSUME_YES=true
        run "$I/00_bootstrap.sh"
        ensure_render
        run "$I/facts.sh"
        run "$I/01_pre_check.sh"
        run "$I/02_os_prepare.sh"
        run "$I/03_reboot.sh"
        run "$I/facts.sh"            # 重启后内核信息刷新
        run "$I/04_runtime.sh"
        run "$I/05_image_push.sh"
        run "$I/06_lb.sh"
        run "$I/07_k8s_install.sh"
        run "$I/08_storage.sh"
        run "$I/09_addons.sh"
        run "$I/10_post_check.sh"
        echo -e "${GREEN}[DONE] 集群部署完成${NC}"
        ;;
    upgrade)
        sub=${1:-}; shift 2>/dev/null
        case "$sub" in
            build)     bash "$U/build_upgrade_pkg.sh" "$@" ;;
            push)      ensure_facts; run "$U/k8s_upgrade_image_push.sh" "$@" ;;
            precheck)  ensure_facts; run "$U/k8s_upgrade_pre_check.sh" "$@" ;;
            backup)    ensure_facts; run "$U/k8s_upgrade_backup.sh" "$@" ;;
            run)       ensure_facts; run "$U/k8s_upgrade.sh" "$@" ;;
            postcheck) ensure_facts; run "$U/k8s_upgrade_post_check.sh" "$@" ;;
            rollback)  ensure_facts; run "$U/k8s_upgrade_rollback.sh" "$@" ;;
            all)
                ensure_facts
                run "$U/k8s_upgrade_image_push.sh"
                run "$U/k8s_upgrade_pre_check.sh"
                run "$U/k8s_upgrade_backup.sh"
                run "$U/k8s_upgrade.sh" "$@"
                run "$U/k8s_upgrade_post_check.sh"
                ;;
            *) usage; exit 1 ;;
        esac
        ;;
    migrate-pkg) bash "$S/tools/migrate_pkg.sh" "$@" && { echo; bash "$S/tools/verify_pkg.sh"; } ;;
    verify-pkg)  bash "$S/tools/verify_pkg.sh" "$@" ;;
    fetch-images) bash "$S/tools/fetch_images.sh" "$@" ;;
    bundle)      bash "$S/tools/make_bundle.sh" "$@" ;;
    menu)
        cat <<'EOF'
==============================================
  K8s 离线自动化部署（x86_64 / aarch64）
==============================================
  1. 一键部署（全部步骤）
  2. 部署前检查
  3. 单步执行（输入步骤名）
  4. 升级（全部步骤）
  5. 卸载集群
  h. 查看全部命令
EOF
        read -r -p "请选择: " ch
        case "$ch" in
            1) exec bash "$0" install ;;
            2) exec bash "$0" precheck ;;
            3) read -r -p "步骤名(precheck/os/reboot/runtime/images/lb/k8s/storage/addons/postcheck): " st; exec bash "$0" "$st" ;;
            4) exec bash "$0" upgrade all ;;
            5) exec bash "$0" uninstall ;;
            *) usage ;;
        esac
        ;;
    *) usage; exit 1 ;;
esac
