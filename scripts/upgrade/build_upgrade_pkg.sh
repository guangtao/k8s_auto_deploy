#!/usr/bin/env bash
# ============================================================
# 制作离线升级包（在可联网的机器上执行，需 docker + curl）
#
# 产物:
#   upgrade-pkg/v<ver>/
#     images.list              kubeadm 所需镜像（name:tag，不含仓库前缀；不含 etcd）
#     sha256sums.txt
#     amd64/bin/{kubeadm,kubelet,kubectl}   amd64/images/*.tar
#     arm64/bin/{kubeadm,kubelet,kubectl}   arm64/images/*.tar
#
# 用法:
#   bash deploy.sh upgrade build -v 1.34.2 [-a amd64,arm64] [-o ../upgrade-pkg]
#        [--bin-url https://dl.k8s.io/release] [--image-src registry.k8s.io]
#
# 国内网络示例:
#   --image-src registry.cn-hangzhou.aliyuncs.com/google_containers
#   --bin-url   https://kubernetes-release.pek3b.qingstor.com/release   （KubeKey zone=cn 使用的镜像站）
# ============================================================
set -o pipefail

VER=""; ARCHS="amd64,arm64"; OUT="$(cd "$(dirname "$0")/../.." && pwd)/upgrade-pkg"
BIN_URL="https://dl.k8s.io/release"; IMG_SRC="registry.k8s.io"

while [ $# -gt 0 ]; do
    case "$1" in
        -v) VER=${2#v}; shift ;;
        -a) ARCHS=$2; shift ;;
        -o) OUT=$2; shift ;;
        --bin-url) BIN_URL=${2%/}; shift ;;
        --image-src) IMG_SRC=${2%/}; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
    shift
done
[ -n "$VER" ] || { echo "必须指定 -v <版本>"; exit 1; }
for c in docker curl sha256sum; do command -v $c >/dev/null || { echo "缺少 $c"; exit 1; }; done

D="$OUT/v$VER"
mkdir -p "$D"
echo "[INFO] 输出目录: $D"

case "$(uname -m)" in x86_64) HOST_ARCH=amd64 ;; aarch64) HOST_ARCH=arm64 ;; *) echo "不支持的主机架构"; exit 1 ;; esac

# ---------- 二进制 ----------
IFS=',' read -r -a ARCH_LIST <<< "$ARCHS"
for a in "${ARCH_LIST[@]}" "$HOST_ARCH"; do
    mkdir -p "$D/$a/bin"
    for b in kubeadm kubelet kubectl; do
        f="$D/$a/bin/$b"
        if [ -x "$f" ]; then echo "[SKIP] $a/$b 已存在"; continue; fi
        url="$BIN_URL/v$VER/bin/linux/$a/$b"
        echo "[GET ] $url"
        curl -fL --retry 3 -o "$f.tmp" "$url" || { echo "[ERROR] 下载失败 $url"; exit 1; }
        if sum=$(curl -fsL --retry 3 "$url.sha256" 2>/dev/null) && [ -n "$sum" ]; then
            echo "${sum%% *}  $f.tmp" | sha256sum -c --quiet - || { echo "[ERROR] sha256 不匹配 $a/$b"; exit 1; }
        else
            echo "[WARN] 未获取到 $url.sha256，跳过上游校验"
        fi
        mv "$f.tmp" "$f"; chmod 0755 "$f"
    done
done

# ---------- 镜像清单 ----------
KUBEADM="$D/$HOST_ARCH/bin/kubeadm"
if [ "$IMG_SRC" = "registry.k8s.io" ]; then
    FULL=$("$KUBEADM" config images list --kubernetes-version "v$VER")
else
    FULL=$("$KUBEADM" config images list --kubernetes-version "v$VER" --image-repository "$IMG_SRC")
fi
FULL=$(grep -v '/etcd:' <<< "$FULL")      # KubeKey 管理 etcd，不随 kubeadm 升级
[ -n "$FULL" ] || { echo "[ERROR] 获取镜像清单失败"; exit 1; }
echo "$FULL" | awk -F/ '{print $NF}' > "$D/images.list"
echo "[INFO] 镜像清单:"; sed 's/^/       /' "$D/images.list"

# ---------- 镜像 ----------
for a in "${ARCH_LIST[@]}"; do
    mkdir -p "$D/$a/images"
    while read -r img; do
        [ -z "$img" ] && continue
        nt=${img##*/}
        f="$D/$a/images/${nt//:/_}.tar"
        if [ -s "$f" ]; then echo "[SKIP] $a $nt"; continue; fi
        echo "[PULL] $a $img"
        docker pull -q --platform "linux/$a" "$img" >/dev/null || { echo "[ERROR] 拉取失败 $img ($a)"; exit 1; }
        real=$(docker image inspect -f '{{.Architecture}}' "$img")
        [ "$real" = "$a" ] || { echo "[ERROR] $img 实际架构 $real != $a"; exit 1; }
        docker save -o "$f" "$img" || { echo "[ERROR] 保存失败 $img"; exit 1; }
        docker rmi "$img" >/dev/null 2>&1 || true
    done <<< "$FULL"
done

# 宿主架构不在目标架构中时，删掉仅用于生成清单的二进制
if [[ ",$ARCHS," != *",$HOST_ARCH,"* ]]; then rm -rf "${D:?}/$HOST_ARCH"; fi

# ---------- 校验文件 ----------
(cd "$D" && find . -type f ! -name sha256sums.txt -print0 | sort -z | xargs -0 sha256sum > sha256sums.txt)
du -sh "$D"
echo "[DONE] v$VER 升级包制作完成，拷贝 $D 到部署机的 k8s-deploy/upgrade-pkg/ 下"
