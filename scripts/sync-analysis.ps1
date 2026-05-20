$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$analysisDir = Join-Path $repoRoot "analysis"
$docsDir = Join-Path $repoRoot "docs"

if (-not (Test-Path -LiteralPath $analysisDir)) {
    throw "analysis directory was not found: $analysisDir"
}

New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
Copy-Item -Path (Join-Path $analysisDir "*.md") -Destination $docsDir -Force

Write-Host "Synced analysis Markdown files to docs."
