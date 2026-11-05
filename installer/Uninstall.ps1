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
. (Join-Path $PSScriptRoot "Common.ps1")

Say "My Singing Monsters Access - uninstaller" Cyan
Say ""

$GamePath = Resolve-GamePath $GamePath
if (-not $GamePath) {
    Say "$ExeName was not found in that folder. Nothing was changed." Red
    exit 1
}
Wait-GameClosed

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
