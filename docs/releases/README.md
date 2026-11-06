# 发布说明（Release Notes）

每个对外发布的部署包版本都有一份发布说明：`v<版本>.md`，版本号与仓库根目录 `VERSION` 一致。

- `bash deploy.sh bundle` 出包时**必须**找到 `docs/releases/v<VERSION>.md`，找不到直接拒绝出包。
- 出包时会在发布说明末尾自动追加「组件版本」表（安装包版本、K8s、Calico、Longhorn、Harbor、镜像数、分支、commit、出包时间），
  生成 `k8s-deploy-v<版本>-<架构>-RELEASE.md` 放在部署包旁边，同时以 `RELEASE.md` 放进包里；上传 OSS 时一起上传。
- 发布说明给现场和客户看：写「变了什么、怎么升级、要注意什么」，不写代码细节（代码细节在 `CHANGELOG.md`）。
- 规则见 [docs/打包与版本规则.md](../打包与版本规则.md)。

## 版本列表

| 版本 | 日期 | 主要内容 |
|---|---|---|
| [v3.1.0](v3.1.0.md) | 2026-11-06 | 首个按版本号发布的部署包：按架构出包、自动上传 OSS；离线内网 DNS、防火墙、jinja2、内核等现场问题修复 |

> v3.0.0 是 2026-10-12 的首版代码（x86/ARM 统一部署），当时的包按 K8s 版本命名（`k8s-deploy-v1.33.4-<架构>-<日期>`），不再使用。

## 模板

新建 `v<版本>.md` 时复制下面的内容：

```markdown
# K8s 离线部署包 v<版本> 发布说明

- 发布日期：YYYY-MM-DD
- 上一版本：v<上一版本>
- 部署包：`k8s-deploy-v<版本>-amd64.tar.xz`、`k8s-deploy-v<版本>-arm64.tar.xz`

## 本版变化

### 新增
- …

### 变更
- …

### 修复
- …

## 升级说明（从 v<上一版本> 升级）

- 未部署完的现场：下载新包，把旧目录的 `scripts/render_config.py` 拷到新包覆盖，执行 `bash deploy.sh render`，再 `bash deploy.sh install -y`（已完成的步骤自动跳过）。
- 已部署好的集群：无需操作 / 需要重跑的步骤 …

配置变化：无 / 新增配置项 …（默认值 …，需要时在 render_config.py 里改）

## 注意事项
- …
```
