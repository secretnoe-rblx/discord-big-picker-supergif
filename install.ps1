#requires -version 5.1
<#
    BigPicker — a large, resizable GIF/emoji panel for Discord.
    The script installs Vencord (the mod loader), adds the BigPicker and SuperGifs plugins, builds everything and patches Discord.
#>

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Vencord",
    [switch]$SkipDiscordPatch,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Say($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Fail($msg) {
    Write-Host ""
    Write-Host "  [error] $msg" -ForegroundColor Red
    Write-Host ""
    if (-not $NoPause) { Read-Host "Press Enter to close" }
    exit 1
}

# runs an external program and returns its exit code (stderr does not crash the script)
function Run($exe, [string[]]$arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $exe @arguments | Out-Host
        return $LASTEXITCODE
    } catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        return 1
    } finally { $ErrorActionPreference = $prev }
}

# corepack is not always in PATH (or missing entirely) — find a working pnpm runner
function Resolve-Pnpm {
    Refresh-Path

    if (Get-Command corepack -ErrorAction SilentlyContinue) {
        return @{ Exe = "corepack"; Args = @("pnpm") }
    }

    $corepackCmd = Join-Path $env:ProgramFiles "nodejs\corepack.cmd"
    if (Test-Path $corepackCmd) {
        return @{ Exe = $corepackCmd; Args = @() }
    }

    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        return @{ Exe = "pnpm"; Args = @() }
    }

    if (Get-Command npx -ErrorAction SilentlyContinue) {
        return @{ Exe = "npx"; Args = @("--yes", "pnpm@12.15.0") }
    }

    Fail "pnpm was not found. Install Node.js LTS from https://nodejs.org/ and run the installer again."
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Test-NodeOk {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        $ver = (& node -v) -replace "^v", ""
        return ([int]($ver.Split(".")[0]) -ge 22)
    } catch { return $false }
}

function Ensure-Tool($wingetId, $displayName, $command, $manualUrl) {
    Refresh-Path
    if (Get-Command $command -ErrorAction SilentlyContinue) {
        Ok "$displayName is already installed"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "$displayName was not found. Install it manually: $manualUrl — then run the installer again."
    }

    Say "Installing $displayName (a UAC prompt may appear — click Yes)"
    Run "winget" @("install", "--id", $wingetId, "-e", "--accept-source-agreements", "--accept-package-agreements") | Out-Null
    Refresh-Path

    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$displayName still did not appear. Install it manually: $manualUrl — then run the installer again."
    }
    Ok "$displayName installed"
}



Write-Host ""
$pluginsRoot = Join-Path $PSScriptRoot "plugins"
foreach ($pluginFile in @("bigPicker.ts", "superGifs.ts")) {
    if (-not (Test-Path (Join-Path $pluginsRoot $pluginFile))) {
        Fail "plugins\$pluginFile was not found next to install.ps1. Extract the whole archive instead of moving files one by one."
    }
}

Write-Host ""
Write-Host "  ==========================================" -ForegroundColor Magenta
Write-Host "   BigPicker for Discord — setup" -ForegroundColor Magenta
Write-Host "  ==========================================" -ForegroundColor Magenta

Say "Checking Node.js"
Ensure-Tool "OpenJS.NodeJS.LTS" "Node.js" "node" "https://nodejs.org/ (LTS version)"
if (-not (Test-NodeOk)) { Fail "Node.js 22 or newer is required. Install the LTS build from https://nodejs.org/ and run the installer again." }
Ok "Node.js: $(& node -v)"

Say "Checking Git"
Ensure-Tool "Git.Git" "Git" "git" "https://git-scm.com/download/win"
Ok "Git: $(& git --version)"

if (Test-Path (Join-Path $PSScriptRoot ".git")) {
    Say "Updating DiscordBigPicker"
    $env:GIT_TERMINAL_PROMPT = "0"
    Push-Location $PSScriptRoot
    try {
        $code = Run "git" @("pull", "--ff-only")
        if ($code -eq 0) { Ok "Updated" }
        else { Warn "Could not update (local changes?), using the current copy" }
    } finally { Pop-Location }
}

Say "Downloading Vencord into $InstallDir"
if (Test-Path (Join-Path $InstallDir "package.json")) {
    Push-Location $InstallDir
    try {
        $code = Run "git" @("pull", "--ff-only")
        if ($code -eq 0) { Ok "Vencord updated" } else { Warn "Update failed, using the existing copy" }
    } finally { Pop-Location }
} else {
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path $InstallDir) | Out-Null
    $code = Run "git" @("clone", "--depth", "1", "https://github.com/Vendicated/Vencord", $InstallDir)
    if ($code -ne 0) { Fail "Could not download Vencord. Check your internet connection and run the installer again." }
    Ok "Vencord downloaded"
}

Say "Adding the BigPicker plugin"
$bigPickerSource = Join-Path $PSScriptRoot "plugins\bigPicker.ts"
if (-not (Test-Path $bigPickerSource)) {
    Fail "plugins\bigPicker.ts was not found next to install.ps1. Extract the whole archive instead of moving files one by one."
}
$pluginDir = Join-Path $InstallDir "src\userplugins\bigPicker"
New-Item -ItemType Directory -Force $pluginDir | Out-Null
Copy-Item $bigPickerSource (Join-Path $pluginDir "index.ts") -Force
Ok "Plugin installed"

Say "Adding the SuperGifs plugin"
$superGifsSource = Join-Path $PSScriptRoot "plugins\superGifs.ts"
if (-not (Test-Path $superGifsSource)) {
    Fail "plugins\superGifs.ts was not found next to install.ps1. Extract the whole archive instead of moving files one by one."
}
$superGifsDir = Join-Path $InstallDir "src\userplugins\superGifs"
New-Item -ItemType Directory -Force $superGifsDir | Out-Null
Copy-Item $superGifsSource (Join-Path $superGifsDir "index.ts") -Force
Ok "SuperGifs installed"

$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = "0"
$pnpm = Resolve-Pnpm
Push-Location $InstallDir
try {
    Say "Installing dependencies (1-2 minutes)"
    $code = Run $pnpm.Exe ($pnpm.Args + @("install", "--frozen-lockfile"))
    if ($code -ne 0) { Fail "pnpm install failed." }

    Say "Building Vencord"
    $code = Run $pnpm.Exe ($pnpm.Args + @("build"))
    if ($code -ne 0) { Fail "The build failed." }
    Ok "Built"
} finally { Pop-Location }

if ($SkipDiscordPatch) {
    Warn "Skipping the Discord patch (-SkipDiscordPatch)"
} else {
    Say "Closing Discord"
    Get-Process Discord -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3

    $installer = Join-Path $env:TEMP "VencordInstallerCli.exe"
    if (-not (Test-Path $installer)) {
        Say "Downloading the Vencord installer"
        Invoke-WebRequest -Uri "https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe" -OutFile $installer -UseBasicParsing
    }

    Say "Patching Discord (takes one second)"
    $env:VENCORD_USER_DATA_DIR = $InstallDir
    $env:VENCORD_DEV_INSTALL = "1"
    $code = Run $installer @("-install", "-branch", "auto")
    if ($code -ne 0) { Fail "The Vencord installer failed." }

    Say "Starting Discord"
    $updater = Join-Path $env:LOCALAPPDATA "Discord\Update.exe"
    if (Test-Path $updater) {
        Start-Process $updater -ArgumentList "--processStart", "Discord.exe"
    } else {
        Warn "Discord was not found in the default location — start it manually."
    }
}

Write-Host ""
Write-Host "  Done!" -ForegroundColor Green
Write-Host ""
Write-Host "  How to use:" -ForegroundColor White
Write-Host "   - open the GIF picker in any chat"
Write-Host "   - drag the small diagonal handle in the top-left corner to resize the panel"
Write-Host "   - double-click the handle to reset the size"
Write-Host "   - the star on the right side of the search bar opens Super GIFs and your categories"
Write-Host "   - exact sizes: Discord Settings -> Vencord -> Plugins -> BigPicker"
Write-Host ""
Write-Host "  Important: do not delete or move the folder $InstallDir." -ForegroundColor Yellow
Write-Host "  If the panel disappears after a Discord update, run this file again." -ForegroundColor Yellow
Write-Host ""
if (-not $NoPause) { Read-Host "Press Enter to close" }
