#!/usr/bin/env bash
# ============================================================
# 在可联网的机器上按架构拉取镜像并保存到 pkg/<arch>/images/（需要 docker）
# 用于补齐离线包中缺失的镜像，拷回部署机后执行 deploy.sh images 推送
#
# 用法:
#   bash fetch_images.sh -a arm64                    拉取默认的补齐清单（见下方 DEFAULT_IMAGES）
#   bash fetch_images.sh -a arm64 -i <镜像> [-i ...]  拉取指定镜像
#   bash fetch_images.sh -a arm64,amd64 -f list.txt  从文件读取（每行一个镜像）
#   --mirror <前缀>   仅替换 docker.io 镜像的仓库前缀，例如 --mirror docker.m.daocloud.io
#   已存在的输出文件会跳过（可中断后重跑续传）
# ============================================================
set -o pipefail
OUT="$(cd "$(dirname "$0")/../.." && pwd)/pkg"
ARCHS="arm64"; IMAGES=(); MIRROR=""

# 2.1.2 ARM 包缺失 / 放错架构的镜像
DEFAULT_IMAGES=(
  "registry.k8s.io/metrics-server/metrics-server:v0.7.2"
  "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2|nfs-subdir-external-provisioner:v4.0.0"
  "docker.io/longhornio/support-bundle-kit:v0.0.61"
  "docker.io/osixia/keepalived:2.0.20|keepalived:latest"
)

while [ $# -gt 0 ]; do
    case "$1" in
        -a) ARCHS=$2; shift ;;
        -i) IMAGES+=("$2"); shift ;;
        -f) mapfile -t -O "${#IMAGES[@]}" IMAGES < <(grep -vE '^\s*(#|$)' "$2"); shift ;;
        -o) OUT=$2; shift ;;
        --mirror) MIRROR=${2%/}; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数 $1"; exit 1 ;;
    esac
    shift
done
command -v docker >/dev/null || { echo "需要 docker"; exit 1; }
[ ${#IMAGES[@]} -eq 0 ] && IMAGES=("${DEFAULT_IMAGES[@]}")

rc=0
IFS=',' read -r -a AL <<< "$ARCHS"
for a in "${AL[@]}"; do
    mkdir -p "$OUT/$a/images"
    for spec in "${IMAGES[@]}"; do
        src=${spec%%|*}; as=""
        [[ "$spec" == *"|"* ]] && as=${spec#*|}         # 保存时使用的名字（与模板中的镜像名对齐）
        pull=$src
        if [ -n "$MIRROR" ] && [[ "$src" == docker.io/* ]]; then pull="$MIRROR/${src#docker.io/}"; fi
        save_name=${as:-$src}
        f="$OUT/$a/images/fetched_$(echo "${save_name##*/}" | tr ':/' '__').tar"
        if [ -s "$f" ]; then echo "[SKIP] $a  $save_name 已存在"; continue; fi
        echo "[PULL] $a  $pull"
        if ! docker pull -q --platform "linux/$a" "$pull" >/dev/null; then echo "[ERROR] 拉取失败 $pull"; rc=1; continue; fi
        real=$(docker image inspect -f '{{.Architecture}}' "$pull")
        [ "$real" = "$a" ] || { echo "[ERROR] $pull 没有 $a 版本（得到 $real）"; rc=1; continue; }
        save=$pull
        if [ -n "$as" ]; then save="fetched/$as"; docker tag "$pull" "$save"; fi
        docker save -o "$f.tmp" "$save" && mv "$f.tmp" "$f" && echo "[SAVE] $f" || { rm -f "$f.tmp"; rc=1; }
        docker rmi "$pull" "$save" >/dev/null 2>&1 || true
    done
done
[ $rc -eq 0 ] && echo "[DONE] 完成，拷回部署机后执行: bash deploy.sh verify-pkg && bash deploy.sh images" || echo "[WARN] 部分镜像失败"
exit $rc
