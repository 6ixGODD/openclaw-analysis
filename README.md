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

可以用发布脚本创建并推送版本 tag：

```powershell
./scripts/release.ps1 1.0.0
```

脚本会生成 `v1.0.0` 形式的 annotated tag，并在 push 到远程前要求确认。推送成功后，GitHub Pages workflow 会被 tag 触发。

如果部署阶段报错：

```text
Tag "v1.0.0" is not allowed to deploy to github-pages due to environment protection rules.
```

需要在 GitHub 仓库中允许 tag 部署：

1. 打开 Settings -> Environments -> github-pages。
2. 找到 Deployment branches and tags。
3. 添加 deployment branch or tag rule。
4. Ref type 选择 Tag，Name pattern 填 `v*`。
5. 保存后重新运行失败的 Pages workflow。
