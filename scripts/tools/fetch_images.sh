#!/usr/bin/env bash
# ============================================================
# 按架构拉取镜像并保存到 pkg/<arch>/images/（打包机，需要 docker + 外网）
#
# 只下载缺的：开始前会扫描 pkg/<arch>/images 下已有的镜像 tar（按 tar 内真实的镜像名和架构，
# 不看文件名），清单里已存在且架构正确的镜像直接跳过。所以可以先把已有的离线包传到打包机，
# 再执行本命令补齐。
#
# 用法:
#   bash fetch_images.sh -a amd64,arm64 -f images/images-v1.33.4.txt   按清单补齐
#   bash fetch_images.sh -a arm64 -i <镜像>[|<保存名>[|<架构,...>]] [-i ...]   拉取指定镜像
#   清单行第三段可限定架构，如 docker.io/osixia/keepalived:2.0.20|keepalived:latest|amd64
#   bash fetch_images.sh ... --plan          只列出需要下载的镜像，不下载（不需要 docker）
#   bash fetch_images.sh ... --force         忽略已有镜像，全部重新拉取
#   --mirror <前缀>   仅替换 docker.io 镜像的仓库前缀，例如 --mirror docker.m.daocloud.io
#   不带 -f / -i 时使用 images/images-v1.33.4.txt
# ============================================================
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/pkg"
INDEXER="$ROOT/scripts/lib/image_index.py"
ARCHS="amd64,arm64"; IMAGES=(); MIRROR=""; PLAN=false; FORCE=false

while [ $# -gt 0 ]; do
    case "$1" in
        -a) ARCHS=$2; shift ;;
        -i) IMAGES+=("$2"); shift ;;
        -f) mapfile -t -O "${#IMAGES[@]}" IMAGES < <(grep -vE '^\s*(#|$)' "$2" | sed 's/\s*$//'); shift ;;
        -o) OUT=$2; shift ;;
        --mirror) MIRROR=${2%/}; shift ;;
        --plan) PLAN=true ;;
        --force) FORCE=true ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "未知参数 $1"; exit 1 ;;
    esac
    shift
done
if [ ${#IMAGES[@]} -eq 0 ]; then
    mapfile -t IMAGES < <(grep -vE '^\s*(#|$)' "$ROOT/images/images-v1.33.4.txt" | sed 's/\s*$//')
fi
$PLAN || command -v docker >/dev/null || { echo "需要 docker"; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }

# 与 lib/images.sh normalize_nametag 相同的归一化
normalize() {
    local nt=${1##*/}
    [[ "$nt" == *:* ]] || nt="$nt:latest"
    sed -E 's/[-_](linux[-_])?(amd64|arm64|aarch64|x86_64)$//' <<< "$nt"
}

rc=0; total_new=0
IFS=',' read -r -a AL <<< "$ARCHS"
for a in "${AL[@]}"; do
    mkdir -p "$OUT/$a/images"
    have=""
    if ! $FORCE; then
        shopt -s nullglob; tars=("$OUT/$a/images"/*.tar); shopt -u nullglob
        if [ ${#tars[@]} -gt 0 ]; then
            echo "[SCAN] $a: 扫描已有 ${#tars[@]} 个镜像包..."
            idx=$(python3 "$INDEXER" "${tars[@]}")
            have=$(awk -F'\t' -v a="$a" '$2==a{print $3}' <<< "$idx" | sort -u)
            bad=$(awk -F'\t' -v a="$a" '$2!=a{print "    " $1 " (" $2 ")"}' <<< "$idx")
            [ -n "$bad" ] && { echo "[WARN] $a 目录中以下文件架构不对或损坏，不计入已有（建议移走）:"; echo "$bad"; }
        fi
    fi

    todo=(); skipped_arch=0
    for spec in "${IMAGES[@]}"; do
        IFS='|' read -r src as only <<< "$spec"
        if [ -n "$only" ] && [[ ",$only," != *",$a,"* ]]; then skipped_arch=$((skipped_arch + 1)); continue; fi
        want=$(normalize "${as:-$src}")
        if [ -n "$have" ] && grep -qxF "$want" <<< "$have"; then continue; fi
        todo+=("$spec")
    done
    echo "[PLAN] $a: 清单 ${#IMAGES[@]} 个（其中 $skipped_arch 个不适用 $a），已有 $(( ${#IMAGES[@]} - skipped_arch - ${#todo[@]} )) 个，需下载 ${#todo[@]} 个"
    for spec in "${todo[@]}"; do echo "         - ${spec%%|*}"; done
    total_new=$((total_new + ${#todo[@]}))
    $PLAN && continue

    for spec in "${todo[@]}"; do
        IFS='|' read -r src as _ <<< "$spec"
        pull=$src
        if [ -n "$MIRROR" ] && [[ "$src" == docker.io/* ]]; then pull="$MIRROR/${src#docker.io/}"; fi
        f="$OUT/$a/images/fetched_$(normalize "${as:-$src}" | tr ':/' '__').tar"
        echo "[PULL] $a  $pull"
        if ! docker pull -q --platform "linux/$a" "$pull" >/dev/null; then echo "[ERROR] 拉取失败 $pull"; rc=1; continue; fi
        real=$(docker image inspect -f '{{.Architecture}}' "$pull")
        [ "$real" = "$a" ] || { echo "[ERROR] $pull 没有 $a 版本（得到 $real）"; rc=1; docker rmi "$pull" >/dev/null 2>&1; continue; }
        save=$pull
        if [ -n "$as" ]; then save="fetched/$as"; docker tag "$pull" "$save"; fi
        if docker save -o "$f.tmp" "$save" && mv "$f.tmp" "$f"; then echo "[SAVE] $(basename "$f")"; else rm -f "$f.tmp"; rc=1; fi
        docker rmi "$pull" "$save" >/dev/null 2>&1 || true
    done
done

if $PLAN; then
    echo "[PLAN] 共需下载 $total_new 个（--plan 模式，未下载）"
    exit 0
fi
[ $rc -eq 0 ] && echo "[DONE] 镜像已补齐，下一步: bash deploy.sh verify-pkg" || echo "[WARN] 部分镜像失败（见上方 ERROR），可重跑本命令重试"
exit $rc
