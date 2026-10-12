#!/usr/bin/env bash
# ============================================================
# 出包：把 k8s-deploy（代码 + 指定架构的离线包）打成一个可直接拷到现场的 tar.gz
#
#   bash make_bundle.sh [-a amd64,arm64] [-o <输出目录>] [--with-upgrade] [--force]
#     -a              打包哪些架构（默认 amd64,arm64；纯 x86 现场用 -a amd64 可减小体积）
#     --with-upgrade  同时打包 upgrade-pkg/
#     --force         verify-pkg 有 FAIL 也继续
# 产物: <输出目录>/k8s-deploy-<版本>-<架构>-<日期>.tar.gz 及 .sha256
# ============================================================
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHS="amd64,arm64"; OUTD="$(dirname "$ROOT")"; WITH_UP=false; FORCE=false
while [ $# -gt 0 ]; do
    case "$1" in
        -a) ARCHS=$2; shift ;;
        -o) OUTD=$2; shift ;;
        --with-upgrade) WITH_UP=true ;;
        --force) FORCE=true ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "未知参数 $1"; exit 1 ;;
    esac
    shift
done
IFS=',' read -r -a AL <<< "$ARCHS"

echo "[1/3] 校验离线包: ${AL[*]}"
if ! bash "$ROOT/scripts/tools/verify_pkg.sh" "${AL[@]}"; then
    $FORCE || { echo "[ERROR] 离线包校验未通过（加 --force 强制出包）"; exit 1; }
    echo "[WARN] 校验未通过，--force 继续"
fi

VER=$(sed -n "s/^ *'version': *'\([0-9.]*\)'.*/\1/p" "$ROOT/scripts/render_config.py" | head -1)
NAME="k8s-deploy-v${VER:-x}-$(IFS=-; echo "${AL[*]}")-$(date +%Y%m%d)"
OUT="$OUTD/$NAME.tar.gz"
mkdir -p "$OUTD"

base=$(basename "$ROOT")
inc=("$base/deploy.sh" "$base/README.md" "$base/scripts" "$base/template" "$base/images"
     "$base/pkg/README.txt" "$base/config/.gitkeep" "$base/logs/.gitkeep" "$base/work/.gitkeep")
[ -f "$ROOT/pkg/STATUS.md" ] && inc+=("$base/pkg/STATUS.md")
for a in "${AL[@]}"; do
    [ -d "$ROOT/pkg/$a" ] || { echo "[ERROR] 缺少 pkg/$a"; exit 1; }
    inc+=("$base/pkg/$a")
done
if $WITH_UP; then inc+=("$base/upgrade-pkg"); else inc+=("$base/upgrade-pkg/README.txt"); fi

echo "[2/3] 打包 -> $OUT（$(du -shc "${inc[@]/#/$(dirname "$ROOT")/}" 2>/dev/null | tail -1 | cut -f1)，请稍候）"
comp="gzip"; command -v pigz >/dev/null && comp="pigz"
tar -C "$(dirname "$ROOT")" -I "$comp" -cf "$OUT.tmp" --exclude='*.tmp' --exclude='__pycache__' "${inc[@]}" \
    && mv "$OUT.tmp" "$OUT" || { rm -f "$OUT.tmp"; echo "[ERROR] 打包失败"; exit 1; }

echo "[3/3] 校验和"
(cd "$OUTD" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
ls -lh "$OUT"; cat "$OUT.sha256"
echo "[DONE] 现场: tar xzf $NAME.tar.gz && cd $base && bash deploy.sh"
