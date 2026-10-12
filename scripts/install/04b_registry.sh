#!/usr/bin/env bash
# ============================================================
# 04b 部署镜像仓库（可选，harbor.install=True 时执行）
#   amd64 节点: Harbor 2.10.2 离线安装（安装包来自 KubeKey 制品或 pkg/amd64/harbor/）
#   arm64 节点: registry:2（Harbor 官方无 arm64 离线包；自备 arm64 安装包可设 harbor.type=harbor）
#   https: 自动生成自签 CA + 服务端证书（SAN 含仓库 IP），各节点通过 containerd certs.d / docker
#          insecure-registries 跳过校验（04 步已配置）
# 已在运行且健康则跳过；可重复执行
# ============================================================
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
start_log 04b-registry
require_root
check_ssh_tools

if [ "$HARBOR_INSTALL" != true ]; then
    log_info "harbor.install=False，使用现场已有仓库 $HARBOR_SCHEME://$HARBOR_REGISTRY，本步跳过"
    exit 0
fi

N=$(registry_node)
IP=$(node_ip "$N")
ARCH=$(node_arch "$N")
REG_HOST=${HARBOR_REGISTRY%%:*}
REG_PORT=""; [[ "$HARBOR_REGISTRY" == *:* ]] && REG_PORT=${HARBOR_REGISTRY##*:}
TYPE=$HARBOR_TYPE
[ "$TYPE" = auto ] && { [ "$ARCH" = amd64 ] && TYPE=harbor || TYPE=registry; }
URL="$HARBOR_SCHEME://$HARBOR_REGISTRY"
HDIR="$(pkg_arch_dir "$ARCH")/harbor"
log_info "仓库节点 $N ($IP, $ARCH)  类型 $TYPE  地址 $URL  数据目录 $HARBOR_DATA_DIR"

healthy() {
    if [ "$TYPE" = harbor ]; then
        curl -sk --max-time 5 "$URL/api/v2.0/health" | grep -q '"status":"healthy"'
    else
        [ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$URL/v2/")" = 200 ]
    fi
}
if healthy; then
    log_info "$URL 已在运行且健康，跳过安装"
    state_set registry_type "$TYPE"
    exit 0
fi

run_remote "$N" "docker info >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1" \
    || die "[$N] docker / docker-compose 不可用，请先执行 04 步（deploy.sh runtime）"

# ---------------- 证书（https）----------------
CERT_DIR="$RENDERED/registry-certs"
if [ "$HARBOR_SCHEME" = https ]; then
    require_cmds openssl
    if [ ! -s "$CERT_DIR/server.crt" ] || ! openssl x509 -in "$CERT_DIR/server.crt" -noout -text | grep -q "IP Address:$IP"; then
        log_info "生成自签证书（CA 10 年，SAN: IP:$IP）"
        mkdir -p "$CERT_DIR"
        san="IP:$IP"; [ "$REG_HOST" != "$IP" ] && san="$san,DNS:$REG_HOST"
        openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 3650 -subj "/CN=k8s-deploy-registry-ca" \
            -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" 2>/dev/null || die "CA 生成失败"
        openssl req -nodes -newkey rsa:4096 -sha256 -subj "/CN=$REG_HOST" \
            -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" 2>/dev/null || die "CSR 生成失败"
        printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "$CERT_DIR/ext.cnf"
        openssl x509 -req -sha256 -days 3650 -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
            -CAcreateserial -extfile "$CERT_DIR/ext.cnf" -out "$CERT_DIR/server.crt" 2>/dev/null || die "证书签发失败"
    fi
    rm -rf "$CERT_DIR/node" && mkdir -p "$CERT_DIR/node" && cp "$CERT_DIR"/{server.crt,server.key,ca.crt} "$CERT_DIR/node/"
    copy_to "$N" "$CERT_DIR/node" "$HARBOR_DATA_DIR/cert" || die "[$N] 证书下发失败"   # CA 私钥只留在部署机
fi

# ---------------- Harbor ----------------
install_harbor() {
    local tgz
    tgz=$(ls "$HDIR"/harbor-offline-installer-*.tgz 2>/dev/null | head -1)
    if [ -z "$tgz" ]; then
        local art; art=$(ls "$(pkg_arch_dir "$ARCH")"/artifact/*.tar.gz 2>/dev/null | head -1)
        [ -n "$art" ] || die "缺少 Harbor 安装包：$HDIR/harbor-offline-installer-*.tgz"
        local member
        member=$(tar tzf "$art" 2>/dev/null | grep -E "^registry/harbor/[^/]+/$ARCH/harbor-offline-installer-.*\.tgz$" | head -1)
        [ -n "$member" ] || die "$ARCH 没有 Harbor 离线安装包（KubeKey 制品中也没有）；可改用 harbor.type=registry"
        log_info "从 KubeKey 制品中提取 $(basename "$member")（较大，请稍候）"
        mkdir -p "$HDIR"
        tar xzf "$art" -C "$HDIR" --strip-components=4 "$member" || die "提取 Harbor 安装包失败"
        tgz="$HDIR/$(basename "$member")"
    fi
    log_info "下发 $(basename "$tgz") 到 $N"
    copy_to "$N" "$tgz" "$REMOTE_WORK/harbor-installer.tgz" || die "[$N] 安装包传输失败"

    local hport="" sport="" ypw qpw
    ypw="'${HARBOR_PASSWD//\'/\'\'}'"        # YAML 单引号字符串（' 写成 ''），# $ 等字符原样保留
    qpw=$(printf '%q' "$ypw")                  # 安全传入远程 shell
    if [ -n "$REG_PORT" ]; then [ "$HARBOR_SCHEME" = https ] && sport=$REG_PORT || hport=$REG_PORT; fi
    log_step "[$N] 安装 Harbor（加载镜像需要几分钟）"
    run_remote "$N" "set -e
mkdir -p /opt '$HARBOR_DATA_DIR'
rm -rf /opt/harbor && tar xzf $REMOTE_WORK/harbor-installer.tgz -C /opt
cd /opt/harbor
cp harbor.yml.tmpl harbor.yml
sed -i 's#^hostname: .*#hostname: $REG_HOST#' harbor.yml
PW=$qpw awk '/^harbor_admin_password:/{print \"harbor_admin_password: \" ENVIRON[\"PW\"]; next} 1' harbor.yml > harbor.yml.new && mv harbor.yml.new harbor.yml
sed -i 's#^data_volume: .*#data_volume: $HARBOR_DATA_DIR#' harbor.yml
if [ '$HARBOR_SCHEME' = https ]; then
    sed -i 's#^  certificate: .*#  certificate: $HARBOR_DATA_DIR/cert/server.crt#' harbor.yml
    sed -i 's#^  private_key: .*#  private_key: $HARBOR_DATA_DIR/cert/server.key#' harbor.yml
    [ -n '$sport' ] && sed -i '/^https:/,/^  port:/s#^  port: .*#  port: $sport#' harbor.yml
else
    sed -i '/^https:/,/^  private_key:/s/^/#/' harbor.yml
    [ -n '$hport' ] && sed -i '/^http:/,/^  port:/s#^  port: .*#  port: $hport#' harbor.yml
fi
grep -nE '^(hostname|data_volume|harbor_admin_password)|certificate|private_key|^#?https?:' harbor.yml | sed 's/harbor_admin_password: .*/harbor_admin_password: ******/'
./install.sh > $REMOTE_WORK/harbor-install.log 2>&1 || { tail -30 $REMOTE_WORK/harbor-install.log; exit 1; }
tail -3 $REMOTE_WORK/harbor-install.log" || die "[$N] Harbor 安装失败（日志: $N:$REMOTE_WORK/harbor-install.log）"

    # 开机自启：Harbor 容器 restart=always，docker 已 enable；这里再加一个 systemd 单元兜底
    run_remote "$N" "cat > /etc/systemd/system/harbor.service <<'EOF'
[Unit]
Description=Harbor (k8s-deploy)
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/harbor
ExecStart=/usr/bin/docker-compose -f /opt/harbor/docker-compose.yml up -d
ExecStop=/usr/bin/docker-compose -f /opt/harbor/docker-compose.yml down
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable harbor.service >/dev/null 2>&1" || log_warn "[$N] harbor.service 创建失败（不影响使用）"
}

# ---------------- registry:2 ----------------
install_registry() {
    local tarf="$HDIR/registry.tar"
    [ -f "$tarf" ] || die "缺少 $tarf（registry:2 镜像，可由 migrate-pkg 从 2.1.2 包整理，或 docker save registry:2）"
    copy_to "$N" "$tarf" "$REMOTE_WORK/registry.tar" || die "[$N] 传输失败"
    local port=${REG_PORT:-$([ "$HARBOR_SCHEME" = https ] && echo 443 || echo 80)} tls=""
    [ "$HARBOR_SCHEME" = https ] && tls="-v $HARBOR_DATA_DIR/cert:/certs:ro -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/server.crt -e REGISTRY_HTTP_TLS_KEY=/certs/server.key"
    log_step "[$N] 启动 registry:2（端口 $port）"
    run_remote "$N" "set -e
img=\$(docker load -i $REMOTE_WORK/registry.tar | sed -n 's/^Loaded image: //p' | head -1)
[ -n \"\$img\" ] || { echo '镜像加载失败'; exit 1; }
mkdir -p '$HARBOR_DATA_DIR/registry'
docker rm -f k8s-registry >/dev/null 2>&1 || true
docker run -d --name k8s-registry --restart=always -p $port:5000 \
  -v '$HARBOR_DATA_DIR/registry':/var/lib/registry -e REGISTRY_STORAGE_DELETE_ENABLED=true $tls \"\$img\"" \
        || die "[$N] registry 启动失败"
    log_warn "registry:2 不做账号认证；harbor.user/passwd 不生效（docker login 仍可正常通过）"
}

if [ "$TYPE" = harbor ]; then install_harbor; else install_registry; fi

log_info "等待 $URL 就绪"
for _ in $(seq 1 60); do healthy && break; sleep 5; done
healthy || die "$URL 5 分钟内未就绪，请登录 $N 检查: docker ps -a"
state_set registry_type "$TYPE"
log_info "镜像仓库就绪: $URL（$TYPE）"
[ "$TYPE" = harbor ] && log_info "Harbor 控制台: $URL  账号 admin / harbor.passwd"
