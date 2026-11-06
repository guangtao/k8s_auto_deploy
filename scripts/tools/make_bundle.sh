#!/usr/bin/env bash
# ============================================================
# 出包（打包机）：代码 + 指定架构的离线包 -> 一个可直接拷到现场的压缩包
#
#   bash deploy.sh bundle -a arm64                 # 纯 ARM 现场：只打 arm64 的东西
#   bash deploy.sh bundle -a amd64                 # 纯 x86 现场
#   bash deploy.sh bundle -a amd64,arm64           # 混合架构集群
#
# 为了减小体积，默认会：
#   1. 只打 -a 指定架构的 pkg/<arch>，其它架构一个字节都不带
#   2. 镜像只带 images/images-v1.33.4.txt 里启用（未注释）且适用该架构的；清单外的
#      （kata、cilium、kube-ovn、hybridnet、multus ...）不带。--all-images 带全部
#   3. 同一架构的镜像合并成一个 tar，共享的层只存一份（docker load 一次加载全部）
#   4. KubeKey 制品去掉 images/（镜像另外推送，不需要）、registry/ 和其它架构的二进制；
#      Harbor 安装包挪到 pkg/<arch>/harbor/；制品以未压缩 tar 放入，由外层统一压缩
#   5. 外层用 xz 多线程压缩（比 gzip 小约 1/3；现场只需要 tar + xz，所有发行版自带）
#
# 选项:
#   -a <arch,...>        amd64 / arm64 / amd64,arm64（必填）
#   -o <目录>            输出目录（默认代码目录的上一级）
#   -c xz|zst|gz         压缩方式（默认 xz；zst 压缩/解压快很多，体积接近 xz，但现场需要 zstd 命令）
#   -l <级别>            压缩级别（默认 xz 6 / zst 19 / gz 6；xz 9 只再小 1~2%，慢且吃内存）
#   --split <大小>       按大小切分，如 4G（FAT32 U 盘单文件 <4G）、2G
#   --all-images         带上 pkg/<arch>/images 下的全部镜像（不按清单过滤）
#   --extra-images <n:t,...>  清单之外再带的镜像（归一化 name:tag，如 cilium:v1.15.3）
#   --no-merge           不合并镜像（逐个 tar 原样打包）
#   --no-harbor          不带 Harbor 离线安装包（现场已有 Harbor 时，可省约 640MB/架构）
#   --with-upgrade       同时打包 upgrade-pkg/
#   --no-test            不做压缩包完整性自检（自检会完整解压校验一遍）
#   --force              verify-pkg 有 FAIL 也继续
#   --overwrite          产出目录或 OSS 上已有同名包时覆盖（默认拒绝，提示先升 VERSION）
#   --oss-dest <oss://…/> 上传目录（默认 oss://cyberdownland/k8s_install/，也可用环境变量 OSS_DEST）
#   --no-upload          只在本地出包，不上传 OSS
#
# 版本号：仓库根目录 VERSION 文件（x.y.z，安装包自己的版本，与 K8s 版本无关），规则见 docs/打包与版本规则.md
#   每个版本必须有发布说明 docs/releases/v<版本>.md，否则拒绝出包
# 上传 OSS：自检通过后用 ossutil 上传安装包（或分卷）、.sha256、-RELEASE.md、-DEPLOY.md，并逐个核对。
#   打包机需要 ossutil（v1/v2 均可，PATH 里叫 ossutil 或 ossutil64，或环境变量 OSSUTIL 指定），
#   并已 ossutil config 配好 AccessKey（密钥只在打包机上，不进仓库）。打包前先检查权限和同名包。
# 产物: <输出目录>/k8s-deploy-v<版本>-<架构>.tar.xz（或分卷 .part00 ...）、.sha256、-RELEASE.md、-DEPLOY.md
# ============================================================
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
ARCHS=""; OUTD="$(dirname "$ROOT")"; COMP=xz; LEVEL=""; SPLIT=""; ALL_IMAGES=false; EXTRA=""
MERGE=true; HARBOR=true; WITH_UP=false; TEST=true; FORCE=false
OVERWRITE=false; UPLOAD=true; OSS_DEST="${OSS_DEST:-oss://cyberdownland/k8s_install/}"
while [ $# -gt 0 ]; do
    case "$1" in
        -a) ARCHS=$2; shift ;;
        -o) OUTD=$2; shift ;;
        -c) COMP=$2; shift ;;
        -l) LEVEL=$2; shift ;;
        --split) SPLIT=$2; shift ;;
        --all-images) ALL_IMAGES=true ;;
        --extra-images) EXTRA=$2; shift ;;
        --no-merge) MERGE=false ;;
        --no-harbor) HARBOR=false ;;
        --with-upgrade) WITH_UP=true ;;
        --no-test) TEST=false ;;
        --force) FORCE=true ;;
        --overwrite) OVERWRITE=true ;;
        --oss-dest) OSS_DEST=$2; shift ;;
        --no-upload) UPLOAD=false ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "未知参数 $1（-h 查看帮助）"; exit 1 ;;
    esac
    shift
done
die()  { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }
info() { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
step() { echo -e "\n\033[1;36m==== $* ====\033[0m"; }

[ -n "$ARCHS" ] || die "请用 -a 指定架构：-a amd64 | -a arm64 | -a amd64,arm64"
IFS=',' read -r -a AL <<< "$ARCHS"
for a in "${AL[@]}"; do
    case "$a" in amd64|arm64) ;; *) die "不支持的架构 $a（只能是 amd64 / arm64）" ;; esac
    [ -d "$ROOT/pkg/$a" ] || die "缺少 pkg/$a"
done
case "$COMP" in
    xz)  LEVEL=${LEVEL:-6};  EXT=tar.xz;  COMPRESS=(xz -T0 "-$LEVEL" -c);              DTEST=(xz -T0 -dc) ;;
    zst) LEVEL=${LEVEL:-19}; EXT=tar.zst; COMPRESS=(zstd -T0 "-$LEVEL" --long=27 -q -c); DTEST=(zstd -dc -q) ;;
    gz)  LEVEL=${LEVEL:-6};  EXT=tar.gz
         if command -v pigz >/dev/null; then COMPRESS=(pigz "-$LEVEL" -c); else COMPRESS=(gzip "-$LEVEL" -c); fi
         DTEST=(gzip -dc) ;;
    *) die "-c 只能是 xz / zst / gz" ;;
esac
command -v "${COMPRESS[0]}" >/dev/null || die "打包机缺少 ${COMPRESS[0]} 命令"
command -v python3 >/dev/null || die "需要 python3"

# K8s 版本只作为组件信息记录；安装包版本取 VERSION 文件
VER=$(sed -n "s/^ *'version': *'\([0-9.]*\)'.*/\1/p" "$ROOT/scripts/render_config.py" | head -1)
PKG_VER=$(tr -d ' \r\n' < "$ROOT/VERSION" 2>/dev/null)
[[ "$PKG_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 文件缺失或格式不对（应为 x.y.z，如 3.0.0），读到: '$PKG_VER'"
REL_SRC="$ROOT/docs/releases/v$PKG_VER.md"
[ -f "$REL_SRC" ] || die "缺少发布说明 docs/releases/v$PKG_VER.md。每个版本出包前必须写发布说明（模板见 docs/releases/README.md）"
GIT_COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
GIT_BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    warn "有未提交的代码修改，会按当前文件打进包（BUNDLE_INFO 里的 commit 与实际内容不一致）；正式出包前请先提交"
fi
NAME="k8s-deploy-v${PKG_VER}-$(IFS=-; echo "${AL[*]}")"
mkdir -p "$OUTD"; OUTD=$(cd "$OUTD" && pwd)
OUT="$OUTD/$NAME.$EXT"
# 同名包已存在：多半是改了代码没升 VERSION，默认不覆盖
if ! $OVERWRITE && compgen -G "$OUTD/$NAME.$EXT*" >/dev/null; then
    die "$OUTD 下已有 $NAME.$EXT。代码有变化请先升 VERSION（规则见 docs/打包与版本规则.md）；确认是同一版本重打，加 --overwrite"
fi
# 上传前置检查：ossutil 可用、有权限、OSS 上没有同名包（出包要几十分钟，失败要趁早）
if $UPLOAD; then
    [[ "$OSS_DEST" == oss://* ]] || die "--oss-dest 必须以 oss:// 开头: $OSS_DEST"
    OSS_DEST="${OSS_DEST%/}/"
    OSSUTIL="${OSSUTIL:-$(command -v ossutil || command -v ossutil64 || true)}"
    [ -n "$OSSUTIL" ] && [ -x "$OSSUTIL" ] || die "找不到 ossutil。安装后执行 ossutil config 配置 AccessKey，或用环境变量 OSSUTIL 指定路径；只想本地出包加 --no-upload"
    "$OSSUTIL" ls "$OSS_DEST" >/dev/null 2>&1 || die "ossutil 无法访问 $OSS_DEST（检查 ossutil config 的 AccessKey、地域及对 bucket 的权限）；只想本地出包加 --no-upload"
    for n in "$NAME.$EXT" "$NAME.$EXT.part00"; do
        if "$OSSUTIL" stat "$OSS_DEST$n" >/dev/null 2>&1 && ! $OVERWRITE; then
            die "OSS 上已有 $OSS_DEST$n。代码有变化请先升 VERSION；确认是同一版本重传，加 --overwrite"
        fi
    done
    info "出包完成后上传到 $OSS_DEST（ossutil: $OSSUTIL）"
fi
STAGE="$OUTD/.stage-$NAME.$$"     # 带 PID，多次出包互不干扰
# 同一个包同一时间只允许一个出包进程（同时跑两次会互相删掉/改写对方的临时文件）
exec 8> "$OUTD/.$NAME.lock"
if ! flock -n 8; then
    die "已有另一个 bundle 进程在出同一个包（$NAME），请等它结束，或用 ps -ef | grep make_bundle 找到后结束它"
fi
# 清理以前被强制中断留下的临时目录（对应进程已不存在）
for old in "$OUTD"/.stage-"$NAME".*; do
    [ -d "$old" ] || continue
    pid=${old##*.}; [ "$pid" = $$ ] && continue
    kill -0 "$pid" 2>/dev/null || rm -rf "$old"
done
T0=$(date +%s)

# ---------------- 1. 校验 ----------------
step "1/5 校验离线包: ${AL[*]}"
if ! bash "$ROOT/scripts/tools/verify_pkg.sh" "${AL[@]}"; then
    $FORCE || die "离线包校验未通过（修复后重试，或加 --force 强制出包）"
    warn "校验未通过，--force 继续"
fi

need=0; for a in "${AL[@]}"; do need=$((need + $(du -smL "$ROOT/pkg/$a" | cut -f1))); done
avail=$(df -Pm "$OUTD" | awk 'NR==2{print $4}')
info "输出目录 $OUTD 可用 ${avail}MB；出包临时目录 + 产物最多约需 ${need}MB"
[ "${avail:-0}" -ge "$need" ] || warn "输出目录空间可能不够（可用 -o 指定其它磁盘）"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE" "$OUT.tmp"' EXIT
trap 'exit 130' INT TERM
# 原样打包的文件（相对 ROOT）和生成的文件（相对 STAGE）
FROM_ROOT=(deploy.sh README.md DEPLOY.md VERSION CHANGELOG.md docs scripts template images pkg/README.txt
           config/.gitkeep logs/.gitkeep work/.gitkeep)
FROM_STAGE=(BUNDLE_INFO.txt RELEASE.md)
if $WITH_UP; then FROM_ROOT+=(upgrade-pkg); else FROM_ROOT+=(upgrade-pkg/README.txt); fi
for f in "${FROM_ROOT[@]}"; do [ -e "$ROOT/$f" ] || die "缺少 $f"; done

# 与 lib/images.sh normalize_nametag 一致
normalize() {
    local nt=${1##*/}
    [[ "$nt" == *:* ]] || nt="$nt:latest"
    sed -E 's/[-_](linux[-_])?(amd64|arm64|aarch64|x86_64)$//' <<< "$nt"
}
LIST="$ROOT/images/images-v1.33.4.txt"
wanted_for() {   # arch -> 归一化 name:tag 列表
    local a=$1 src as only
    grep -vE '^\s*(#|$)' "$LIST" | sed 's/\s*$//' | while IFS='|' read -r src as only; do
        if [ -n "$only" ] && [[ ",$only," != *",$a,"* ]]; then continue; fi
        normalize "${as:-$src}"
    done
    tr ',' '\n' <<< "$EXTRA" | sed '/^$/d' | while read -r x; do normalize "$x"; done
}

INFO="$STAGE/BUNDLE_INFO.txt"
{
    echo "k8s-deploy 离线部署包"
    echo "安装包版本: v$PKG_VER"
    echo "包名:     $NAME.$EXT"
    echo "架构:     ${AL[*]}"
    echo "K8s:      v${VER:-?}"
    echo "分支:     $GIT_BRANCH"
    echo "commit:   $GIT_COMMIT"
    echo "代码版本: $(git -C "$ROOT" log -1 --format='%h %ci %s' 2>/dev/null || echo '未知')"
    echo "出包时间: $(date '+%F %T')  出包机: $(hostname)"
    echo "选项:     compress=$COMP-$LEVEL merge=$MERGE harbor=$HARBOR all_images=$ALL_IMAGES upgrade=$WITH_UP${EXTRA:+ extra=$EXTRA}"
} > "$INFO"

# ---------------- 2. 每个架构的离线包 ----------------
for a in "${AL[@]}"; do
    d="$ROOT/pkg/$a"; sd="$STAGE/pkg/$a"
    step "2/5 [$a] 镜像"
    mkdir -p "$sd/images"
    shopt -s nullglob; tars=("$d"/images/*.tar); shopt -u nullglob
    [ ${#tars[@]} -gt 0 ] || die "pkg/$a/images 下没有镜像"
    idx=$(python3 "$LIB/image_index.py" "${tars[@]}") || die "镜像索引失败"
    wanted=$(wanted_for "$a" | sort -u)
    have=$(awk -F'\t' -v a="$a" '$2==a{print $3}' <<< "$idx" | sort -u)
    miss=$(comm -23 <(echo "$wanted") <(echo "$have") | sed '/^$/d')
    [ -n "$miss" ] && warn "清单中以下镜像在 pkg/$a/images 里没有（先执行 fetch-images 补齐）:" && sed 's/^/          /' <<< "$miss"
    if $ALL_IMAGES; then
        sel=$have
    else
        sel=$(comm -12 <(echo "$wanted") <(echo "$have") | sed '/^$/d')
        drop=$(comm -13 <(echo "$wanted") <(echo "$have") | sed '/^$/d' | tr '\n' ' ')
        [ -n "$drop" ] && info "不在清单中、不打包: $drop"
    fi
    echo "$sel" > "$STAGE/.wanted-$a"
    src_sz=$(du -cm "${tars[@]}" | tail -1 | cut -f1)
    if $MERGE; then
        info "合并 $(grep -c . <<< "$sel") 个镜像（共享层去重）-> images/images-$a.tar"
        python3 "$LIB/merge_images.py" -o "$sd/images/images-$a.tar" --arch "$a" -w "$STAGE/.wanted-$a" "${tars[@]}" \
            > "$STAGE/.merge-$a.log" || { cat "$STAGE/.merge-$a.log"; die "[$a] 镜像合并失败（可加 --no-merge 绕过）"; }
        got=$(python3 "$LIB/image_index.py" "$sd/images/images-$a.tar" | awk -F'\t' -v a="$a" '$2==a{print $3}' | sort -u)
        lost=$(comm -23 <(echo "$sel") <(echo "$got") | sed '/^$/d')
        [ -z "$lost" ] || die "[$a] 合并结果缺少镜像: $lost"
        FROM_STAGE+=("pkg/$a/images")
        info "镜像 ${src_sz}MB（目录内全部） -> $(du -m "$sd/images/images-$a.tar" | cut -f1)MB（清单内、去重后）"
    else
        files=$(awk -F'\t' -v a="$a" 'NR==FNR{w[$0]=1; next} $2==a && ($3 in w){print $1}' "$STAGE/.wanted-$a" - <<< "$idx" | sort -u)
        n=0; sz=0
        for f in $files; do FROM_ROOT+=("pkg/$a/images/$f"); n=$((n + 1)); sz=$((sz + $(du -m "$d/images/$f" | cut -f1))); done
        info "镜像 ${src_sz}MB -> $n 个 tar ${sz}MB"
    fi
    { echo; echo "[$a] 镜像 ($(grep -c . <<< "$sel") 个):"; sed 's/^/  /' <<< "$sel"; } >> "$INFO"
    echo "$sel" > "$sd/images/IMAGES.txt"; $MERGE || FROM_STAGE+=("pkg/$a/images/IMAGES.txt")

    step "2/5 [$a] KubeKey 制品"
    art=$(ls "$d"/artifact/*.tar.gz "$d"/artifact/*.tar 2>/dev/null | head -1)
    [ -n "$art" ] || die "缺少 pkg/$a/artifact/*.tar[.gz]"
    mkdir -p "$sd/artifact" "$sd/harbor"
    if [ -f "$d/artifact/SLIM" ]; then
        info "$(basename "$art") 已是精简制品，原样打包"
        FROM_ROOT+=("pkg/$a/artifact")
    else
        other=$([ "$a" = amd64 ] && echo arm64 || echo amd64)
        lst=$(tar tf "$art") || die "读取 $(basename "$art") 失败"
        hmem=$(grep -E "(^|/)registry/harbor/[^/]+/$a/harbor-offline-installer-[^/]*\.tgz$" <<< "$lst" | head -1)
        if $HARBOR && [ -n "$hmem" ] && ! ls "$d"/harbor/harbor-offline-installer-*.tgz >/dev/null 2>&1; then
            info "从制品中取出 Harbor 安装包 $(basename "$hmem") -> pkg/$a/harbor/"
            tar xf "$art" -C "$sd/harbor" --strip-components="$(awk -F/ '{print NF-1}' <<< "$hmem")" "$hmem" \
                || die "提取 Harbor 安装包失败"
        fi
        tmp="$STAGE/.art-$a"; mkdir -p "$tmp"
        info "精简制品: 去掉 images/ registry/ $other/（解压中，请稍候）"
        tar xf "$art" -C "$tmp" --anchored --exclude=images --exclude=./images --exclude=registry --exclude=./registry \
            --no-anchored --exclude="$other" || die "解压 $(basename "$art") 失败"
        # KubeKey 下载的二进制常常没有可执行位，出包时补上
        find "$tmp" -type f -path "*/$a/*" ! -name '*.tgz' ! -name '*.tar*' ! -name '*.gz' -exec chmod +x {} + 2>/dev/null
        kv=$(cd "$tmp" && ls -d kube/v*/"$a"/kubeadm 2>/dev/null | head -1)
        [ -n "$kv" ] || die "精简后的制品中没有 kube/v*/$a/kubeadm"
        slim="ks3.4-artifact-$a-slim.tar"
        (cd "$tmp" && tar cf "$sd/artifact/$slim" --owner=0 --group=0 --numeric-owner -- *) || die "生成精简制品失败"
        rm -rf "$tmp"
        echo "KubeKey 制品精简版（make_bundle 生成）：已去掉 images/ registry/ 和非 $a 的二进制，源: $(basename "$art")" > "$sd/artifact/SLIM"
        FROM_STAGE+=("pkg/$a/artifact")
        info "制品 $(du -m "$art" | cut -f1)MB(压缩) -> $(du -m "$sd/artifact/$slim" | cut -f1)MB(未压缩，外层统一压缩)  含 $kv"
    fi

    step "2/5 [$a] 其它"
    chmod +x "$d/kk" "$d/docker/docker-compose" 2>/dev/null || true   # 经 Windows 中转的包会丢可执行位
    for f in kk docker os kernel bootstrap; do [ -e "$d/$f" ] && FROM_ROOT+=("pkg/$a/$f"); done
    [ -f "$d/harbor/registry.tar" ] && FROM_ROOT+=("pkg/$a/harbor/registry.tar")
    if $HARBOR; then
        for f in "$d"/harbor/harbor-offline-installer-*.tgz; do [ -f "$f" ] && FROM_ROOT+=("pkg/$a/harbor/$(basename "$f")"); done
        compgen -G "$d/harbor/harbor-offline-installer-*.tgz" >/dev/null || compgen -G "$sd/harbor/harbor-offline-installer-*.tgz" >/dev/null \
            || warn "$a 没有 Harbor 安装包，现场 harbor.install=True 时该架构的仓库节点会使用 registry:2"
    else
        info "--no-harbor：不带 Harbor 安装包（保留 registry.tar）"
    fi
    FROM_STAGE+=("pkg/$a/harbor")
done

# 发布说明 = docs/releases/v<版本>.md + 自动生成的组件版本表；包内一份 RELEASE.md，包旁一份 -RELEASE.md
imgver() { grep -vE '^\s*#' "$LIST" | grep -m1 -oE "/$1:[^|[:space:]]+" | cut -d: -f2; }
{
    cat "$REL_SRC"; echo; echo "---"; echo
    echo "## 组件版本（出包时自动生成）"; echo
    echo "| 组件 | 版本 |"; echo "|---|---|"
    echo "| 安装包 | v$PKG_VER |"
    echo "| 架构 | ${AL[*]} |"
    echo "| Kubernetes | v${VER:-?} |"
    echo "| Calico | $(imgver node) |"
    echo "| Longhorn | $(imgver longhorn-manager) |"
    echo "| metrics-server | $(imgver metrics-server) |"
    echo "| Docker | $(ls "$ROOT/pkg/${AL[0]}/docker" 2>/dev/null | sed -n 's/^docker-\([0-9.]*\)\.tgz$/\1/p' | head -1) |"
    for a in "${AL[@]}"; do
        h=$(ls "$ROOT/pkg/$a"/harbor/harbor-offline-installer-*.tgz "$STAGE/pkg/$a"/harbor/harbor-offline-installer-*.tgz 2>/dev/null | head -1)
        $HARBOR && [ -n "$h" ] && echo "| Harbor（$a） | $(basename "$h" .tgz | sed 's/^harbor-offline-installer-//') |"
    done
    for a in "${AL[@]}"; do echo "| 镜像数（$a） | $(grep -c . "$STAGE/pkg/$a/images/IMAGES.txt" 2>/dev/null || echo ?) |"; done
    echo "| 分支 / commit | $GIT_BRANCH / ${GIT_COMMIT:0:12} |"
    echo "| 出包时间 | $(date '+%F %T %z') |"
} > "$STAGE/RELEASE.md"

# ---------------- 3. 打包 ----------------
step "3/5 打包 + 压缩（$COMP -$LEVEL）"
# 估算原始大小
raw=0
for f in "${FROM_ROOT[@]}"; do raw=$((raw + $(du -smL "$ROOT/$f" | cut -f1))); done
for f in "${FROM_STAGE[@]}"; do raw=$((raw + $(du -sm "$STAGE/$f" | cut -f1))); done
echo >> "$INFO"; echo "未压缩大小: ${raw}MB" >> "$INFO"
info "未压缩 ${raw}MB -> $OUT（$COMP 多线程，按 CPU 核数；整包通常需要十几到几十分钟）"
# --transform 只改成员名，不改符号链接目标（S）
tar -cf - --hard-dereference --owner=0 --group=0 --numeric-owner \
    --exclude='__pycache__' --exclude='*.tmp' --transform 's,^,k8s-deploy/,S' \
    -C "$ROOT" "${FROM_ROOT[@]}" -C "$STAGE" "${FROM_STAGE[@]}" \
    | "${COMPRESS[@]}" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT" || { rm -f "$OUT.tmp"; die "打包失败（看上方 tar 报错；常见原因：磁盘空间不足，或同时运行了两个 bundle）"; }
cp "$ROOT/DEPLOY.md" "$OUTD/$NAME-DEPLOY.md"
cp "$STAGE/RELEASE.md" "$OUTD/$NAME-RELEASE.md"

# ---------------- 4. 自检 ----------------
if $TEST; then
    step "4/5 完整性自检（完整解压一遍）"
    n=$("${DTEST[@]}" "$OUT" | tar tf - | wc -l) || die "压缩包自检失败"
    info "自检通过，$n 个文件"
else
    step "4/5 跳过自检（--no-test）"
fi

# ---------------- 5. 校验和 / 分卷 ----------------
step "5/5 校验和${SPLIT:+ + 分卷 $SPLIT}"
cd "$OUTD" || die "无法进入 $OUTD"
rm -f "$NAME.$EXT.part"* "$NAME.sha256"
rm -f "$NAME.DEPLOY.md"   # 旧版命名
sha256sum "$NAME.$EXT" > "$NAME.sha256"
if [ -n "$SPLIT" ]; then
    split -b "$SPLIT" -d -a 2 "$NAME.$EXT" "$NAME.$EXT.part" || die "分卷失败"
    rm -f "$NAME.$EXT"
    sha256sum "$NAME.$EXT".part* >> "$NAME.sha256"
fi
ls -lh "$NAME".* | awk '{print "  " $5 "\t" $9}'
info "用时 $(( ($(date +%s) - T0) / 60 )) 分钟，压缩后 $(du -cm "$NAME.$EXT"* | tail -1 | cut -f1)MB（未压缩 ${raw}MB）"
echo
echo "拷到现场部署机的目录（如 /opt）后:"
if [ -n "$SPLIT" ]; then
    echo "  sha256sum -c --ignore-missing $NAME.sha256          # 校验各分卷"
    echo "  cat $NAME.$EXT.part* > $NAME.$EXT && sha256sum -c --ignore-missing $NAME.sha256"
else
    echo "  sha256sum -c $NAME.sha256"
fi
case "$COMP" in zst) echo "  tar -I zstd -xf $NAME.$EXT && cd k8s-deploy" ;; *) echo "  tar xf $NAME.$EXT && cd k8s-deploy" ;; esac
echo "  然后按 k8s-deploy/DEPLOY.md 部署（同目录下也有一份 $NAME-DEPLOY.md）"

# ---------------- 上传 OSS ----------------
if $UPLOAD; then
    echo; step "上传到 $OSS_DEST"
    UPLOADS=()
    if [ -n "$SPLIT" ]; then UPLOADS+=("$NAME.$EXT".part*); else UPLOADS+=("$NAME.$EXT"); fi
    UPLOADS+=("$NAME.sha256" "$NAME-RELEASE.md" "$NAME-DEPLOY.md")
    failed=""
    for f in "${UPLOADS[@]}"; do
        if "$OSSUTIL" cp -f "$OUTD/$f" "$OSS_DEST" >/dev/null 2>&1 && "$OSSUTIL" stat "$OSS_DEST$f" >/dev/null 2>&1; then
            echo "  已上传 $OSS_DEST$f"
        else
            failed+=" $f"
        fi
    done
    [ -z "$failed" ] || die "上传失败:$failed。文件仍在 $OUTD，可手工补传：$OSSUTIL cp -f $OUTD/<文件> $OSS_DEST"
    info "已全部上传到 $OSS_DEST"
    # 下载地址（内网下载服务按 bucket/目录 + 文件名签名）
    DL_PREFIX="${DL_PREFIX:-http://172.88.1.51:8000/public/sign?bucket_name=$(sed 's#^oss://##; s#/$##' <<< "$OSS_DEST")&package_name=}"
    echo; echo "下载地址与 SHA256（填进部署指南的下载表格）:"
    while read -r sum f; do
        [ -f "$OUTD/$f" ] || { echo "  $f（分卷合并后的整包，SHA256: $sum）"; continue; }
        echo "  $f"; echo "    下载:   $DL_PREFIX$f"; echo "    SHA256: $sum"
    done < "$OUTD/$NAME.sha256"
else
    echo; echo "未上传 OSS（--no-upload）。上传时把安装包、$NAME.sha256、$NAME-RELEASE.md 一起上传到 $OSS_DEST"
fi
