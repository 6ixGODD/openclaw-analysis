# OpenClaw 源码分析

这是一个面向 OpenClaw 源码阅读、架构理解和后续审计的中文文档仓库。文档站点使用 MkDocs 构建，发布内容位于 `docs/`。

根目录下的 `analysis/` 是本地草稿目录，已被 `.gitignore` 排除，不会随仓库提交。需要把本地草稿同步到发布文档时，可以运行：

```powershell
./scripts/sync-analysis.ps1
```

## 本地预览

```powershell
python -m pip install -r requirements.txt
mkdocs serve
```

## 构建检查

```powershell
mkdocs build --strict
```

## 发布

GitHub Pages 由 `.github/workflows/pages.yml` 部署。触发方式包括：

- 发布新的 GitHub Release
- 推送 `v*` 格式的 tag
- 在 Actions 页面手动运行 workflow

仓库推到 GitHub 后，需要在 Settings -> Pages 中将 Source 设置为 GitHub Actions。
