# 版本变更记录

规则见 [docs/打包与版本规则.md](docs/打包与版本规则.md)。每次升版本号，同时更新下表并在下方追加一条记录（新的在上）。
给现场看的发布说明在 [docs/releases/](docs/releases/README.md)。

## 当前最新版本

| 对象 | 版本 | 所在位置 |
|---|---|---|
| 部署包 | 3.1.0 | 仓库根目录 `VERSION`（包名 `k8s-deploy-v3.1.0-<架构>.tar.xz`） |
| Kubernetes | v1.33.4 | `scripts/render_config.py` → `kubernetes.version`，与 `pkg/<arch>/artifact` 一致 |
| 镜像清单 | images-v1.33.4.txt | `images/` |

## 记录

### 2026-11-06（v3.1.0）
- 部署包改用独立版本号 `VERSION`（3.1.0），包名 `k8s-deploy-v<版本>-<架构>.tar.xz`，不再带 K8s 版本和日期。
- `make_bundle.sh`：必须有 `docs/releases/v<版本>.md`；生成 `RELEASE.md`（含组件版本表）；产出目录或 OSS 已有同名包时拒绝（`--overwrite` 覆盖）；出包后上传 `oss://cyberdownland/k8s_install/` 并核对，打印下载地址和 SHA256；`--no-upload`、`--oss-dest`。
- 包含 2026-10-12 ～ 11-06 的全部修复，详见 `docs/releases/v3.1.0.md`。

### 2026-10-12（v3.0.0）
- 首版代码：x86/ARM 统一的 K8s 离线自动化部署与升级（KubeKey + Harbor），包按 K8s 版本命名，未使用独立版本号。
