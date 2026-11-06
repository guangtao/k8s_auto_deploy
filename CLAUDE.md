# k8s-deploy 开发约定

## 改代码必须升版本号

- 部署包版本号在仓库根目录 `VERSION`（x.y.z），与 K8s 版本无关。规则：`docs/打包与版本规则.md`。
- 会进部署包的改动（`deploy.sh`、`scripts/`、`template/`、`images/`、默认配置）在同一次提交里：
  1. 升 `VERSION`：修 bug 升 z；新功能/新配置项升 y；不兼容改动升 x。
  2. 写 `docs/releases/v<新版本>.md`，并加入 `docs/releases/README.md` 版本列表。
  3. 更新 `CHANGELOG.md`。
- 只改文档可以不升。同一天多次提交、中间没出过包，可以合并成一次升级。

## 其它

- 现场补丁 tar 不要包含 `scripts/render_config.py`（会覆盖现场配置）。
- 提交作者用 noreply 邮箱，公网仓库不写内网地址以外的敏感信息、不写密钥。
