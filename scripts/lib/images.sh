# shellcheck shell=bash
# ============================================================
# 多架构镜像推送（部署 / 升级共用）
#   <dir>/<arch>/images/*.tar  ->  <repo>/<name>:<tag>-<arch>  ->  manifest list <repo>/<name>:<tag>
# 节点拉 <name>:<tag> 时 containerd 按本机架构自动选择，x86 / ARM / 混合集群共用同一个 tag。
#
# 镜像名归一化：去掉仓库前缀，并去掉 tag 上的架构后缀
#   172.88.0.2/kubesre/metrics-server:v0.7.2-linux-amd64  -> metrics-server:v0.7.2
#   172.88.0.45/deploy/kube-vip:v1.2.1                    -> kube-vip:v1.2.1
# ============================================================

normalize_nametag() {
    local nt=${1##*/} name tag
    name=${nt%%:*}; tag=${nt#*:}
    [ "$tag" = "$nt" ] && tag=latest
    tag=$(sed -E 's/[-_](linux[-_])?(amd64|arm64|aarch64|x86_64)$//' <<< "$tag")
    echo "$name:$tag"
}

harbor_api() {   # method path [data]
    local url="${HARBOR_SCHEME}://${HARBOR_REGISTRY}/api/v2.0$2"
    curl -sk -o /dev/null -w '%{http_code}' -u "$HARBOR_USER:$HARBOR_PASSWD" -X "$1" \
        -H 'Content-Type: application/json' ${3:+-d "$3"} "$url"
}

ensure_harbor_project() {
    local project=$1 code
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${HARBOR_SCHEME}://${HARBOR_REGISTRY}/api/v2.0/ping")" != 200 ]; then
        log_info "仓库不是 Harbor（如 registry:2），无需创建项目"
        return 0
    fi
    code=$(harbor_api HEAD "/projects?project_name=$project")
    if [ "$code" = "200" ]; then
        log_info "Harbor 项目 $project 已存在"
        return 0
    fi
    if [ "$HARBOR_CREATE_PROJECT" != "true" ]; then
        log_warn "Harbor 项目 $project 不存在（code=$code）且未开启自动创建"
        return 1
    fi
    code=$(harbor_api POST /projects "{\"project_name\":\"$project\",\"metadata\":{\"public\":\"true\"}}")
    case "$code" in
        201|409) log_info "Harbor 项目 $project 已就绪 (code=$code)" ;;
        *) log_warn "创建 Harbor 项目 $project 返回 $code，若推送失败请手工创建（需公开项目）" ;;
    esac
}

docker_login_registry() {
    echo "$HARBOR_PASSWD" | docker login -u "$HARBOR_USER" --password-stdin "${1%%/*}" >/dev/null \
        || die "登录 ${1%%/*} 失败（http 仓库需在 /etc/docker/daemon.json 的 insecure-registries 中）"
}

# push_multiarch <镜像根目录(含 <arch>/images)> <repo> [需要覆盖的架构...]
# 结果: PUSHED_IMAGES（nametag 列表），返回非 0 表示有失败
push_multiarch() {
    local root=$1 repo=$2; shift 2
    local need_arches=("$@") ins=() failed=0
    [ "$REGISTRY_INSECURE" = "true" ] && ins=(--insecure)
    declare -gA IMG_ARCHES=()
    PUSHED_IMAGES=()

    local adir arch tarf out src nt dst real
    for adir in "$root"/*/images; do
        [ -d "$adir" ] || continue
        arch=$(basename "$(dirname "$adir")")
        case "$arch" in amd64|arm64) ;; *) continue ;; esac
        log_step "推送 $arch 镜像 ($(find "$adir" -maxdepth 1 -name '*.tar' | wc -l) 个包)"
        for tarf in "$adir"/*.tar; do
            [ -f "$tarf" ] || continue
            out=$(docker load -i "$tarf" 2>&1) || { log_error "load 失败: $tarf"; failed=1; continue; }
            # 一个 tar 里可能有多个镜像
            while read -r src; do
                [ -z "$src" ] && continue
                real=$(docker image inspect -f '{{.Architecture}}' "$src" 2>/dev/null)
                [ "$real" = "aarch64" ] && real=arm64
                if [ -n "$real" ] && [ "$real" != "$arch" ]; then
                    log_error "$(basename "$tarf"): $src 实际架构 $real，与目录 $arch 不符，已跳过（请放到 $real 目录）"
                    failed=1; continue
                fi
                nt=$(normalize_nametag "$src")
                dst="$repo/${nt}-${arch}"
                if docker tag "$src" "$dst" && docker push -q "$dst" >/dev/null; then
                    log_info "  $arch  $nt"
                    [[ " ${IMG_ARCHES[$nt]:-} " == *" $arch "* ]] || IMG_ARCHES[$nt]="${IMG_ARCHES[$nt]:-} $arch"   # 同一镜像多个包时去重
                else
                    log_error "push 失败: $dst"; failed=1
                fi
                docker rmi "$dst" >/dev/null 2>&1 || true
            done < <(sed -n 's/^Loaded image: //p' <<< "$out")
            grep -q '^Loaded image ID:' <<< "$out" && ! grep -q '^Loaded image: ' <<< "$out" && {
                log_error "$(basename "$tarf") 只有镜像 ID 没有 tag，无法推送"; failed=1; }
        done
    done

    log_step "生成多架构 manifest"
    local target refs a
    for nt in "${!IMG_ARCHES[@]}"; do
        target="$repo/$nt"; refs=()
        for a in ${IMG_ARCHES[$nt]}; do refs+=("$repo/${nt}-${a}"); done
        docker manifest rm "$target" >/dev/null 2>&1 || true
        if docker manifest create "${ins[@]}" "$target" "${refs[@]}" >/dev/null; then
            for a in ${IMG_ARCHES[$nt]}; do
                docker manifest annotate "$target" "$repo/${nt}-${a}" --os linux --arch "$a"
            done
            if docker manifest push "${ins[@]}" --purge "$target" >/dev/null; then
                PUSHED_IMAGES+=("$nt")
            else
                log_error "manifest push 失败: $target"; failed=1
            fi
        else
            log_error "manifest create 失败: $target"; failed=1
        fi
    done

    # 覆盖率：集群里有的架构，每个镜像都应该有
    if [ ${#need_arches[@]} -gt 0 ]; then
        local miss=0
        for nt in $(printf '%s\n' "${!IMG_ARCHES[@]}" | sort); do
            for a in "${need_arches[@]}"; do
                [[ " ${IMG_ARCHES[$nt]} " == *" $a "* ]] || { log_warn "镜像 $nt 缺少 $a 版本，$a 节点上将无法运行"; miss=$((miss + 1)); }
            done
        done
        [ $miss -eq 0 ] && log_info "所有镜像均覆盖集群架构: ${need_arches[*]}"
    fi
    log_info "manifest 共 ${#PUSHED_IMAGES[@]} 个"
    return $failed
}

# image_exists <repo/name:tag>
image_exists() {
    local ins=(); [ "$REGISTRY_INSECURE" = "true" ] && ins=(--insecure)
    docker manifest inspect "${ins[@]}" "$1" >/dev/null 2>&1
}
