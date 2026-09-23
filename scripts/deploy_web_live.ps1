# scripts/deploy_web_live.ps1
# Builds FingerSpeak Web and deploys to the gh-pages branch of neurobridge-v2

$ErrorActionPreference = "Stop"
Write-Host "==> Building and Prerendering FingerSpeak Web App for GitHub Pages..." -ForegroundColor Cyan

$RepoRoot = Resolve-Path "$PSScriptRoot\.."
$WebDir = "$RepoRoot\apps\web"
$PagesDist = "$WebDir\pages-dist"

Set-Location $WebDir
npm run build
node ./prerender-pages.mjs ./pages-dist --base=/neurobridge-v2 --serve-check

Write-Host "==> Pushing to gh-pages branch on origin..." -ForegroundColor Cyan
Set-Location $PagesDist

if (-not (Test-Path ".git")) {
    git init
    git checkout -b gh-pages
    git config user.name "Mysunat Islam"
    git config user.email "mysunatislam@gmail.com"
    git remote add origin "https://github.com/mysunatislam/neurobridge-v2.git"
}

git add -A
git commit -m "Deploy FingerSpeak web app to GitHub Pages" --allow-empty
git push -u origin gh-pages --force

Write-Host "==> Successfully pushed to gh-pages! Live URL: https://mysunatislam.github.io/neurobridge-v2/" -ForegroundColor Green
