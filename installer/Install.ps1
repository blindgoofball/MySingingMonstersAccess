<#
.SYNOPSIS
    Installs My Singing Monsters Access (and Jeode, if missing).
.DESCRIPTION
    1. Finds the game folder (Steam libraries), or asks for it.
    2. Installs the Jeode mod loader from its GitHub releases if it isn't there.
    3. Copies the mod into <game>\mods\msm-a11y.
    4. Builds the menu hooks from YOUR copy of the game's menu files.
    Run it through install.bat. Safe to run again (that is also how you update).
.PARAMETER GamePath
    The folder that contains MySingingMonsters.exe. Found automatically if omitted.
#>
param(
    [string]$GamePath
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$ModSource = Join-Path $Root "mod\msm-a11y"

. (Join-Path $Here "Common.ps1")

function Fail([string]$text) {
    Say ""
    Say "INSTALL FAILED: $text" Red
    Say ""
    exit 1
}
function Ask([string]$question) {
    $answer = Read-Host "$question (y/n)"
    return $answer.Trim().ToLower().StartsWith("y")
}

Say "My Singing Monsters Access - installer" Cyan
Say "==================================================" Cyan
Say ""

if (-not (Test-Path (Join-Path $ModSource "a11y.dll"))) {
    Fail "the mod files are missing next to this installer (expected $ModSource). Extract the whole zip first, then run install.bat from the extracted folder."
}

$GamePath = Resolve-GamePath $GamePath
if (-not $GamePath) {
    Fail "$ExeName was not found in that folder. Run install.bat again and give the folder that contains $ExeName."
}

# --- The game must be closed -------------------------------------------------
Wait-GameClosed

# --- Jeode -------------------------------------------------------------------
$jeodeDll = Join-Path $GamePath "jeode\libjeode.dll"
$proxyDll = Join-Path $GamePath "winhttp.dll"
if ((Test-Path $jeodeDll) -and (Test-Path $proxyDll)) {
    Say "Jeode mod loader: already installed." Green
} else {
    Say ""
    Say "The Jeode mod loader is not installed. The mod needs it to run." Yellow
    Say "Jeode is a separate project: https://github.com/Paficent/jeode"
    Say "Note: some antivirus programs (Windows Defender, Avast, AVG) wrongly flag Jeode."
    Say "If yours removes it, add the game folder as an exclusion and run this installer again."
    if (-not (Ask "Download and install the latest Jeode now?")) {
        Fail "Jeode is required. Install it from https://github.com/Paficent/jeode/releases/latest and run install.bat again."
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ "User-Agent" = "msm-a11y-installer" }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/Paficent/jeode/releases/latest" -Headers $headers
        Say "Latest Jeode release: $($release.tag_name)"
        $assets = @{}
        foreach ($a in $release.assets) { $assets[$a.name] = $a.browser_download_url }
        foreach ($need in @("winhttp.dll", "libjeode.dll")) {
            if (-not $assets.ContainsKey($need)) { throw "the release has no $need" }
        }
        New-Item -ItemType Directory -Force (Join-Path $GamePath "jeode") | Out-Null
        Invoke-WebRequest -Uri $assets["winhttp.dll"] -OutFile $proxyDll -Headers $headers -UseBasicParsing
        Invoke-WebRequest -Uri $assets["libjeode.dll"] -OutFile $jeodeDll -Headers $headers -UseBasicParsing
    } catch {
        Fail "could not download Jeode ($($_.Exception.Message)). Install it by hand from https://github.com/Paficent/jeode/releases/latest (put winhttp.dll in the game folder and libjeode.dll in a 'jeode' folder inside it), then run install.bat again."
    }
    Say "Jeode installed." Green
}

# --- The mod -----------------------------------------------------------------
$modDest = Join-Path $GamePath "mods\msm-a11y"
Say ""
Say "Installing the mod into $modDest ..."
if (Test-Path $modDest) { Remove-Item -Recurse -Force $modDest }
New-Item -ItemType Directory -Force $modDest | Out-Null
Copy-Item -Recurse -Force (Join-Path $ModSource "*") $modDest

if (-not (Test-Path (Join-Path $modDest "prism.dll"))) {
    Say "Warning: prism.dll is missing, so the mod will not be able to speak." Yellow
}

# --- Menu hooks, built from this player's own game files ---------------------
Say "Building the menu hooks from your game's menu files (takes a few seconds)..."
try {
    & (Join-Path $Here "Build-MenuOverrides.ps1") -GamePath $GamePath -OutDir (Join-Path $modDest "data\menus")
} catch {
    Fail "could not build the menu hooks: $($_.Exception.Message)"
}

Say ""
Say "INSTALLED." Green
Say ""
Say "Next:"
Say "  1. Start My Singing Monsters from Steam as usual."
Say "  2. While it loads you should hear: 'My Singing Monsters accessibility mod loaded via Jeode.'"
Say "  3. Press Control+Shift+A for status. The README lists every key."
Say ""
Say "After a game update, run install.bat again so the menu hooks match the new game files."
Say "If something goes wrong, the log is at: $GamePath\data\accessibility.log"
Say ""
