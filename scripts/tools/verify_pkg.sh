#!/usr/bin/env bash
# ============================================================
# 校验 pkg/{amd64,arm64} 离线包：
#   - 二进制（kk / docker / docker-compose）的 ELF 架构
#   - artifact 中的 K8s 版本与架构
#   - 每个镜像 tar 的实际架构、是否损坏
#   - 系统包（os/*.tar、kernel）内 rpm/deb 的架构
#   - 部署必需镜像在每个架构下是否齐全
# 用法: bash verify_pkg.sh [amd64|arm64]...   默认两个都查；有 FAIL 时返回 1
# ============================================================
PKG="$(cd "$(dirname "$0")/../.." && pwd)/pkg"
ARCHES=("$@"); [ ${#ARCHES[@]} -eq 0 ] && ARCHES=(amd64 arm64)
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
FAIL=0; WARN=0
ok()   { echo -e "  ${G}[OK]${N}   $*"; }
warn() { echo -e "  ${Y}[WARN]${N} $*"; WARN=$((WARN + 1)); }
bad()  { echo -e "  ${R}[FAIL]${N} $*"; FAIL=$((FAIL + 1)); }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }

# 部署必需的镜像（name:tag，归一化后）；"可选" 的只告警
REQUIRED="pause:3.9 kube-apiserver:v1.33.4 kube-controller-manager:v1.33.4 kube-scheduler:v1.33.4 kube-proxy:v1.33.4
coredns:1.9.3 k8s-dns-node-cache:1.22.20 cni:v3.27.4 node:v3.27.4 kube-controllers:v3.27.4 pod2daemon-flexvol:v3.27.4 typha:v3.27.4"
LONGHORN="longhorn-manager:v1.9.1 longhorn-engine:v1.9.1 longhorn-instance-manager:v1.9.1 longhorn-share-manager:v1.9.1 longhorn-ui:v1.9.1
csi-attacher:v4.9.0-20250709 csi-provisioner:v5.3.0-20250709 csi-node-driver-registrar:v2.14.0-20250709 csi-resizer:v1.14.0-20250709
csi-snapshotter:v8.3.0-20250709 livenessprobe:v2.16.0-20250709"
OPTIONAL="metrics-server:v0.7.2 nfs-subdir-external-provisioner:v4.0.0 support-bundle-kit:v0.0.61 keepalived:latest kube-vip:v0.7.2 haproxy:2.9.6-alpine"

elf_arch() { case "$(file -b "$1" 2>/dev/null)" in *x86-64*) echo amd64 ;; *aarch64*) echo arm64 ;; *) echo "?" ;; esac; }

IMG_PY='
import tarfile, json, sys, os, re
for f in sorted(sys.argv[1:]):
    b = os.path.basename(f)
    try:
        t = tarfile.open(f)
        m = json.load(t.extractfile("manifest.json"))
        for e in m:
            c = json.load(t.extractfile(e["Config"]))
            for tag in (e.get("RepoTags") or ["<none>"]):
                nt = tag.split("/")[-1]
                if ":" not in nt: nt += ":latest"
                nt = re.sub(r"[-_](linux[-_])?(amd64|arm64|aarch64|x86_64)$", "", nt)
                arch = c.get("architecture")
                print(b + "\t" + str(arch) + "\t" + nt)
    except Exception as ex:
        print(b + "\tBROKEN\t" + (str(ex).splitlines() or ["?"])[0])
'

for a in "${ARCHES[@]}"; do
    d="$PKG/$a"
    echo -e "\n========== $a =========="
    [ -d "$d" ] || { bad "缺少目录 $d"; continue; }

    echo "-- 二进制"
    for f in kk docker/docker-compose; do
        [ -f "$d/$f" ] || { bad "缺少 $f"; continue; }
        fa=$(elf_arch "$d/$f"); [ "$fa" = "$a" ] && ok "$f ($fa)" || bad "$f 架构为 $fa"
    done
    if [ -f "$d/docker/docker-24.0.9.tgz" ]; then
        tar xzOf "$d/docker/docker-24.0.9.tgz" docker/dockerd 2>/dev/null | head -c 64 > /tmp/.vp_dockerd
        fa=$(elf_arch /tmp/.vp_dockerd); [ "$fa" = "$a" ] && ok "docker-24.0.9.tgz ($fa)" || bad "docker-24.0.9.tgz 架构为 $fa"
    else
        bad "缺少 docker/docker-24.0.9.tgz"
    fi

    echo "-- artifact"
    art=$(ls "$d"/artifact/*.tar.gz 2>/dev/null | head -1)
    if [ -n "$art" ]; then
        kv=$(tar tzf "$art" 2>/dev/null | grep -E "^kube/v[^/]+/$a/kubeadm$" | head -1)
        [ -n "$kv" ] && ok "$(basename "$art"): $kv" || bad "$(basename "$art") 中没有 $a 的 kubeadm"
    else
        bad "缺少 artifact/*.tar.gz"
    fi

    echo "-- 镜像仓库（04b 步，可选）"
    if ls "$d"/harbor/harbor-offline-installer-*.tgz >/dev/null 2>&1; then ok "Harbor 安装包 $(basename "$(ls "$d"/harbor/harbor-offline-installer-*.tgz | head -1)")"
    elif [ -n "${art:-}" ] && [ "$a" = amd64 ]; then ok "Harbor 安装包在 KubeKey 制品中（04b 自动提取）"
    else warn "无 Harbor 安装包（$a 仓库节点只能用 registry:2）"; fi
    if [ -f "$d/harbor/registry.tar" ]; then
        ra=$(python3 "$(dirname "$0")/../lib/image_index.py" "$d/harbor/registry.tar" | cut -f2 | head -1)
        [ "$ra" = "$a" ] && ok "harbor/registry.tar ($ra)" || bad "harbor/registry.tar 架构为 $ra"
    else
        warn "无 harbor/registry.tar（harbor.type=registry 时需要）"
    fi

    echo "-- 系统包"
    for f in "$d"/os/*.tar "$d"/kernel/*.tar; do
        [ -f "$f" ] || continue
        lst=$(tar tf "$f" 2>/dev/null) || { bad "$(basename "$f") 损坏"; continue; }
        x=$(grep -cE 'x86_64|_amd64' <<< "$lst"); r=$(grep -cE 'aarch64|_arm64' <<< "$lst")
        if [ "$a" = amd64 ] && [ "$r" -gt 0 ] && [ "$x" -eq 0 ]; then bad "$(basename "$f") 内为 ARM 包"
        elif [ "$a" = arm64 ] && [ "$x" -gt 0 ] && [ "$r" -eq 0 ]; then bad "$(basename "$f") 内为 x86 包"
        else ok "$(basename "$f")"; fi
    done
    # shellcheck disable=SC2010
    have_os=$(ls "$d"/os/ 2>/dev/null | grep -E '^(Centos|Kylin|Uos|Ubuntu|openEuler|rockey)\.tar$' | sed 's/\.tar//' | tr '\n' ' ')
    echo "     可部署的系统: ${have_os:-无}"

    echo "-- 镜像"
    res=$(python3 -c "$IMG_PY" "$d"/images/*.tar) || bad "镜像解析脚本执行失败"
    while IFS=$'\t' read -r f arch nt; do
        [ -z "$f" ] && continue
        if [ "$arch" = BROKEN ]; then bad "$f 损坏: $nt"
        elif [ "$arch" != "$a" ]; then bad "$f 实际架构 $arch"
        fi
    done <<< "$res"
    good=$(awk -F'\t' -v a="$a" '$2==a{print $3}' <<< "$res" | sort -u)
    ok "有效镜像 $(grep -c . <<< "$good") 个"
    for img in $REQUIRED; do grep -qx "$img" <<< "$good" || bad "缺少必需镜像 $img"; done
    for img in $LONGHORN; do grep -qx "$img" <<< "$good" || bad "缺少 Longhorn 镜像 $img"; done
    for img in $OPTIONAL; do grep -qx "$img" <<< "$good" || warn "缺少可选镜像 $img"; done
done

echo -e "\n汇总: ${R}FAIL=$FAIL${N}  ${Y}WARN=$WARN${N}"
[ $FAIL -eq 0 ]
