<#
.SYNOPSIS
    Updates My Singing Monsters Access to the newest release on GitHub.
.DESCRIPTION
    Checks the newest release (pre-releases included) against the version in
    this folder. If it is newer, downloads it, copies it over THIS folder (so
    install.bat here is always the newest version too), then runs the new
    installer. Run it through update.bat.
.PARAMETER GamePath
    The folder that contains MySingingMonsters.exe. Found automatically if omitted.
.PARAMETER Force
    Download and install the newest release even if this folder already has it.
#>
param(
    [string]$GamePath,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here

. (Join-Path $Here "Common.ps1")

function Fail([string]$text) {
    Say ""
    Say "UPDATE FAILED: $text" Red
    Say ""
    exit 1
}

function Get-ManifestVersion([string]$path) {
    try { return ((Get-Content $path -Raw | ConvertFrom-Json).version) } catch { return $null }
}

Say "My Singing Monsters Access - updater" Cyan
Say "==================================================" Cyan
Say ""

$localVersion = Get-ManifestVersion (Join-Path $Root "mod\msm-a11y\manifest.json")
if ($localVersion) { Say "This folder has version $localVersion." }

# --- Newest release ----------------------------------------------------------
Say "Checking GitHub for the newest version..."
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "msm-a11y-updater" }
    # /releases (not /releases/latest): the alphas are pre-releases, which "latest" skips.
    $releases = Invoke-RestMethod -Uri "$RepoApi/releases?per_page=20" -Headers $headers
} catch {
    Fail "could not reach GitHub ($($_.Exception.Message)). Check your internet connection and try again."
}
$release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
if (-not $release) { Fail "no releases were found on GitHub." }
$asset = $release.assets | Where-Object { $_.name -like "msm-a11y-*.zip" } | Select-Object -First 1
if (-not $asset) { Fail "the newest release ($($release.tag_name)) has no download yet. Try again in a few minutes." }
$newVersion = $release.tag_name.TrimStart("v")
Say "Newest version: $newVersion"

if ($localVersion -eq $newVersion -and -not $Force) {
    Say ""
    Say "You already have the newest version ($newVersion)." Green
    Say "To reinstall it anyway, run install.bat."
    exit 0
}

# --- Download into a temporary folder ------------------------------------------
$temp = Join-Path ([IO.Path]::GetTempPath()) ("msm-a11y-update-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $temp | Out-Null
try {
    $zip = Join-Path $temp $asset.name
    Say "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $temp "x") -Force
    # The zip holds one folder (msm-a11y-<version>) with install.bat in it.
    $new = Get-ChildItem (Join-Path $temp "x") -Directory | Where-Object { Test-Path (Join-Path $_.FullName "install.bat") } | Select-Object -First 1
    if (-not $new) { throw "the download did not contain install.bat" }

    # --- Replace this folder's files with the new version -----------------------
    Say "Updating the files in $Root ..."
    Copy-Item -Recurse -Force (Join-Path $new.FullName "*") $Root
} catch {
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
    Fail "could not download or unpack the update ($($_.Exception.Message))."
}
Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue

# --- Install it into the game ----------------------------------------------------
Say ""
Say "Installing version $newVersion into the game..." Cyan
Say ""
if ($GamePath) { & (Join-Path $Root "installer\Install.ps1") -GamePath $GamePath }
else { & (Join-Path $Root "installer\Install.ps1") }
exit $LASTEXITCODE
