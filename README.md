# OpenClaw Analysis

Source-bound architecture notes for the OpenClaw codebase.

The published documentation is built with MkDocs from `docs/`. The local
`analysis/` directory is intentionally ignored so drafts can stay out of Git;
run `scripts/sync-analysis.ps1` before committing when you want to publish
updated analysis content.

## Local Preview

```powershell
python -m pip install -r requirements.txt
mkdocs serve
```

## Publishing

GitHub Pages is deployed by `.github/workflows/pages.yml` when a release is
published, when a `v*` tag is pushed, or when the workflow is run manually.

