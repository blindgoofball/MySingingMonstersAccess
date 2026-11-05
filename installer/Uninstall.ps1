<#
.SYNOPSIS
    Removes the screen reader mod, and optionally the Jeode mod loader.
.PARAMETER GamePath
    The folder that contains MySingingMonsters.exe. Asked for if omitted.
#>
param(
    [string]$GamePath
)

$ErrorActionPreference = "Stop"
$ExeName = "MySingingMonsters.exe"

function Say([string]$text, [string]$color = "White") { Write-Host $text -ForegroundColor $color }

Say "My Singing Monsters Access - uninstaller" Cyan
Say ""

if (-not $GamePath) {
    foreach ($lib in @("${env:ProgramFiles(x86)}\Steam") + ((Get-PSDrive -PSProvider FileSystem).Root | ForEach-Object { Join-Path $_ "SteamLibrary" })) {
        $p = Join-Path $lib "steamapps\common\My Singing Monsters"
        if (Test-Path (Join-Path $p $ExeName)) { $GamePath = $p; break }
    }
    if ($GamePath) { Say "Found the game: $GamePath" Green }
    else { $GamePath = (Read-Host "Paste the game folder path (the one with $ExeName)").Trim().Trim('"') }
}
if (-not (Test-Path (Join-Path $GamePath $ExeName))) {
    Say "$ExeName not found in '$GamePath'. Nothing was changed." Red
    exit 1
}
while (Get-Process -Name "MySingingMonsters" -ErrorAction SilentlyContinue) {
    Say "Close My Singing Monsters, then press Enter." Yellow
    [void](Read-Host)
}

$modDest = Join-Path $GamePath "mods\msm-a11y"
if (Test-Path $modDest) {
    Remove-Item -Recurse -Force $modDest
    Say "Removed the screen reader mod." Green
} else {
    Say "The screen reader mod was not installed."
}

$answer = Read-Host "Also remove the Jeode mod loader? Only say yes if no other mods use it (y/n)"
if ($answer.Trim().ToLower().StartsWith("y")) {
    foreach ($f in @((Join-Path $GamePath "winhttp.dll"), (Join-Path $GamePath "jeode"))) {
        if (Test-Path $f) { Remove-Item -Recurse -Force $f }
    }
    Say "Removed Jeode." Green
}
Say ""
Say "Done. The game is back to normal."
