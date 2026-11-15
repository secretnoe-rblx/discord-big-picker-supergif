#requires -version 5.1
param(
    [string]$VencordDir = "$env:LOCALAPPDATA\Vencord"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path (Join-Path $VencordDir "package.json"))) {
    throw "Vencord was not found at $VencordDir. Run Install.bat first."
}

if (-not (Test-Path (Join-Path $VencordDir "src\userplugins\superGifs\index.ts"))) {
    throw "SuperGifs is not installed in Vencord. Run Install.bat first."
}

Push-Location $VencordDir
try {
    Write-Host "Building Vencord Web..." -ForegroundColor Cyan
    corepack pnpm buildWeb
    if ($LASTEXITCODE -ne 0) { throw "pnpm buildWeb failed." }
} finally {
    Pop-Location
}

$dist = Join-Path $VencordDir "dist"
Copy-Item (Join-Path $dist "extension-chrome.zip") $PSScriptRoot -Force
Copy-Item (Join-Path $dist "extension-firefox.zip") $PSScriptRoot -Force
Copy-Item (Join-Path $dist "Vencord.user.js") $PSScriptRoot -Force

Write-Host "Browser builds updated in $PSScriptRoot" -ForegroundColor Green
