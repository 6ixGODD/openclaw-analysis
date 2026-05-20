param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^v?\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$')]
    [string] $Version,

    [string] $Remote = "origin"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$tag = $Version
if (-not $tag.StartsWith("v")) {
    $tag = "v$tag"
}

$status = git status --porcelain
if ($status) {
    Write-Host "Working tree is not clean. Commit or stash changes before releasing." -ForegroundColor Red
    git status --short
    exit 1
}

git rev-parse --verify --quiet "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Tag already exists locally: $tag" -ForegroundColor Red
    exit 1
}

git ls-remote --exit-code --tags $Remote "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Tag already exists on ${Remote}: $tag" -ForegroundColor Red
    exit 1
}

$head = git rev-parse --short HEAD
Write-Host "Release tag: $tag"
Write-Host "Commit:      $head"
Write-Host "Remote:      $Remote"
Write-Host ""

$answer = Read-Host "Create and push this release tag? Type 'y' to continue"
if ($answer -ne "y") {
    Write-Host "Release cancelled."
    exit 0
}

git tag -a $tag -m "Release $tag"
git push $Remote $tag

Write-Host "Release tag pushed: $tag"
