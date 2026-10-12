#!/usr/bin/env bash
# ============================================================
# 把 2.1.2 的 x86 / ARM 两套安装包整理为 k8s-deploy 的统一离线包目录
#
#   pkg/<arch>/
#     kk                          KubeKey 二进制（来自 scripts/kk）
#     artifact/*.tar.gz           KubeKey 制品（ks3.4-artifact.tar.gz）
#     docker/docker-24.0.9.tgz, docker-compose
#     images/*.tar                全部镜像（ks3.4.1-images/*.tar）
#     os/*.tar                    系统依赖 / nfs / iscsi 离线包（Centos.tar、Kylinnfs.tar、iscsi-kylin.tar ...）
#     kernel/kernel.tar           仅 amd64：CentOS7 kernel-lt
#     bootstrap/<os>/*.rpm        部署机 python3 / sshpass
#     bootstrap/pip/*.whl         jinja2 / MarkupSafe
#
# 用法:
#   bash migrate_pkg.sh --x86 <x86 2.1.2 根目录> --arm <arm 2.1.2 根目录> [--dst ../../pkg] [--mode link|copy|move] [--dry-run]
#   两个参数可只给一个
# 默认 link：同一磁盘上用硬链接，瞬间完成、不占额外空间、不改动原目录（跨盘或不支持时自动退回 copy）。
#   拷贝/打包 k8s-deploy 到其它机器时，硬链接会自然变成普通文件。
# copy：完整复制；move：从原目录移走。
# ============================================================
set -o pipefail
X86=""; ARM=""; MODE=link; DRY=false
DST="$(cd "$(dirname "$0")/../.." && pwd)/pkg"
while [ $# -gt 0 ]; do
    case "$1" in
        --x86) X86=$2; shift ;;
        --arm) ARM=$2; shift ;;
        --dst) DST=$2; shift ;;
        --mode) MODE=$2; shift ;;
        --dry-run) DRY=true ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "未知参数 $1"; exit 1 ;;
    esac
    shift
done
[ -n "$X86$ARM" ] || { echo "至少指定 --x86 或 --arm"; exit 1; }
case "$MODE" in link|copy|move) ;; *) echo "--mode 只能是 link/copy/move"; exit 1 ;; esac

N=0; SKIP=0; WARNS=()
put() {   # src dst_dir [新文件名]
    local src=$1 dd=$2 name=${3:-$(basename "$1")}
    [ -e "$src" ] || return 0
    if [ -e "$dd/$name" ]; then
        # 已是同一文件（硬链接）或大小一致 -> 跳过
        if [ "$(stat -c %d:%i "$src")" = "$(stat -c %d:%i "$dd/$name")" ] || \
           { [ "$MODE" != link ] && [ "$(stat -c %s "$src")" = "$(stat -c %s "$dd/$name")" ]; }; then
            SKIP=$((SKIP + 1)); return 0
        fi
    fi
    echo "  [$MODE] ${src#"$SRC_ROOT"/} -> ${dd#"$DST"/}/$name"
    N=$((N + 1))
    $DRY && return 0
    mkdir -p "$dd"
    case "$MODE" in
        move) mv -f "$src" "$dd/$name" ;;
        copy) cp -f "$src" "$dd/$name" ;;
        link) ln -f "$src" "$dd/$name" 2>/dev/null || { echo "    (硬链接失败，改为复制)"; cp -f "$src" "$dd/$name"; } ;;
    esac
}

file_arch() {   # 用 file 判断 ELF 架构
    case "$(file -b "$1" 2>/dev/null)" in
        *x86-64*) echo amd64 ;; *aarch64*) echo arm64 ;; *) echo unknown ;;
    esac
}

migrate() {
    local root=$1 arch=$2 pkg out
    SRC_ROOT=$root
    pkg="$root/pkg"; out="$DST/$arch"
    [ -d "$pkg" ] || { echo "[ERROR] $pkg 不存在"; exit 1; }
    echo "==== $arch <- $root"

    # kk
    if [ -f "$root/scripts/kk" ]; then
        fa=$(file_arch "$root/scripts/kk")
        [ "$fa" = "$arch" ] || WARNS+=("$root/scripts/kk 架构为 $fa，期望 $arch")
        put "$root/scripts/kk" "$out"
    else
        WARNS+=("$arch: 未找到 scripts/kk")
    fi
    # artifact / docker
    for f in "$pkg"/*artifact*.tar.gz; do put "$f" "$out/artifact"; done
    put "$pkg/docker-24.0.9.tgz" "$out/docker"
    put "$pkg/docker-compose" "$out/docker"
    [ -f "$pkg/docker-compose" ] && { fa=$(file_arch "$pkg/docker-compose"); [ "$fa" = "$arch" ] || WARNS+=("$arch: docker-compose 架构为 $fa"); }
    # images
    for f in "$pkg"/ks3.4.1-images/*.tar; do put "$f" "$out/images"; done
    # os 包
    for f in "$pkg"/{Centos,Kylin,Uos,Ubuntu,openEuler,rockey}.tar "$pkg"/*nfs.tar "$pkg"/iscsi-*.tar; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = nfs.tar ] && continue   # 2.1.2 的 nfs.tar 只是两个 yaml，已由模板替代
        put "$f" "$out/os"
    done
    # kernel（仅 amd64 有意义；ARM 包里的 kernel.tar 实为 x86 rpm，跳过）
    if [ "$arch" = amd64 ] && [ -f "$pkg/kernel.tar" ]; then
        put "$pkg/kernel.tar" "$out/kernel"
    elif [ "$arch" = arm64 ] && [ -f "$pkg/kernel.tar" ]; then
        WARNS+=("arm64: 跳过 pkg/kernel.tar（内容为 x86_64 el7 内核，不适用于 ARM）")
    fi
    # bootstrap
    if [ -d "$pkg/lixian" ]; then
        for d in "$pkg"/lixian/*/; do
            local os; os=$(basename "$d" | tr 'A-Z' 'a-z')
            [ "$os" = openeluer ] && os=openeuler
            [ "$os" = pip ] && continue
            for f in "$d"*.rpm "$d"*.deb; do [ -f "$f" ] && put "$f" "$out/bootstrap/$os"; done
        done
        for f in "$pkg"/lixian/*.whl "$pkg"/lixian/pip/*.whl "$pkg"/lixian/*/pip/*.whl; do
            [ -f "$f" ] && put "$f" "$out/bootstrap/pip"
        done
    fi
}

[ -n "$X86" ] && migrate "$(cd "$X86" && pwd)" amd64
[ -n "$ARM" ] && migrate "$(cd "$ARM" && pwd)" arm64

echo
echo "完成: $N 个文件，跳过已存在 $SKIP 个"
$DRY && echo "（--dry-run 模式，未做任何改动）"
for w in "${WARNS[@]}"; do echo "[WARN] $w"; done
echo "提示: 镜像架构会在推送时（deploy.sh images）逐个校验，放错目录的镜像会被拒绝"
