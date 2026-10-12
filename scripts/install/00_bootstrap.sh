#!/usr/bin/env bash
# ============================================================
# 00 部署机初始化：离线安装 python3 / pip / jinja2 / sshpass
#   自动识别本机架构与系统，不依赖任何配置文件
#   离线包: pkg/<arch>/bootstrap/<os>/*.rpm|*.deb   pkg/<arch>/bootstrap/pip/*.whl
# ============================================================
set -o pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "请使用 root 运行"

case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) die "不支持的架构 $(uname -m)" ;; esac
# shellcheck source=/dev/null
. /etc/os-release
case "$(echo "$ID" | tr 'A-Z' 'a-z')" in
    centos|rhel) OS=centos ;; kylin|neokylin) OS=kylin ;; uos|uniontech|deepin) OS=uos ;;
    ubuntu|debian) OS=ubuntu ;; openeuler) OS=openeuler ;; rocky) OS=rockey ;;
    *) die "不支持的系统 ID=$ID" ;;
esac
info "部署机: $OS / $ARCH"

BOOT="$ROOT_DIR/pkg/$ARCH/bootstrap"

need_py=1; need_jinja=1; need_sshpass=1
command -v python3 >/dev/null 2>&1 && need_py=0
[ $need_py -eq 0 ] && python3 -c 'import jinja2' >/dev/null 2>&1 && need_jinja=0
command -v sshpass >/dev/null 2>&1 && need_sshpass=0

if [ $need_py -eq 0 ] && [ $need_jinja -eq 0 ] && [ $need_sshpass -eq 0 ]; then
    info "python3 / jinja2 / sshpass 均已就绪，跳过"
    exit 0
fi

if [ $need_py -eq 1 ] || [ $need_sshpass -eq 1 ]; then
    d="$BOOT/$OS"
    [ -d "$d" ] || die "缺少离线包目录 $d"
    if ls "$d"/*.rpm >/dev/null 2>&1; then
        info "安装 $d/*.rpm"
        rpm -Uvh --force --nodeps "$d"/*.rpm || warn "部分 rpm 安装返回非 0（已安装的包会报错）"
    elif ls "$d"/*.deb >/dev/null 2>&1; then
        info "安装 $d/*.deb"
        dpkg -i "$d"/*.deb || warn "部分 deb 安装返回非 0"
    else
        die "$d 下没有 rpm/deb"
    fi
fi

command -v python3 >/dev/null 2>&1 || die "python3 安装失败"
if ! python3 -c 'import jinja2' >/dev/null 2>&1; then
    [ -d "$BOOT/pip" ] || die "缺少 $BOOT/pip"
    info "离线安装 jinja2"
    python3 -m pip install --no-index --find-links="$BOOT/pip" jinja2 \
        || pip3 install --no-index --find-links="$BOOT/pip" jinja2 \
        || die "jinja2 安装失败（检查 $BOOT/pip 中 MarkupSafe 的 whl 是否匹配本机 python 版本: $(python3 -V)）"
fi
python3 -c 'import jinja2; print("jinja2", jinja2.__version__)'
command -v sshpass >/dev/null 2>&1 || warn "未安装 sshpass（auth_choice=1/2 需要）"
info "部署机初始化完成"
