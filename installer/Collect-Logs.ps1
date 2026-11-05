<#
.SYNOPSIS
    Zips up everything needed for a bug report onto the Desktop.
.DESCRIPTION
    Collects the mod's log, Jeode's log, recent crash dumps, Jeode's settings,
    the installed mod's manifest and a short system summary. Nothing is sent
    anywhere: the zip is saved on the Desktop for the player to attach.
.PARAMETER GamePath
    The folder that contains MySingingMonsters.exe. Found automatically if omitted.
#>
param(
    [string]$GamePath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common.ps1")

Say "My Singing Monsters Access - collect logs for a bug report" Cyan
Say "==================================================" Cyan
Say ""

$GamePath = Resolve-GamePath $GamePath
if (-not $GamePath) {
    Say "$ExeName was not found in that folder. Nothing was collected." Red
    exit 1
}
if (Get-Process -Name "MySingingMonsters" -ErrorAction SilentlyContinue) {
    Say "Note: the game is still running. That's fine, but if you're reporting a crash or freeze, the log is most complete after the game has closed." Yellow
}

$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$desktop = [Environment]::GetFolderPath("Desktop")
$zip = Join-Path $desktop "msm-access-debug-$stamp.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) ("msm-a11y-debug-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null

function Grab([string]$from, [string]$name) {
    if (Test-Path $from) {
        Copy-Item $from (Join-Path $work $name) -Force
        Say "  added $name"
        return $true
    }
    Say "  not found: $name" DarkGray
    return $false
}

Say "Collecting..."
[void](Grab (Join-Path $GamePath "data\accessibility.log") "accessibility.log")
[void](Grab (Join-Path $GamePath "jeode\latest.log") "jeode-latest.log")
[void](Grab (Join-Path $GamePath "jeode\config.json") "jeode-config.json")
[void](Grab (Join-Path $GamePath "mods\msm-a11y\manifest.json") "mod-manifest.json")

# The newest crash dumps from the last week (each is a few hundred KB).
$dumps = Get-ChildItem $GamePath -Filter "mysingingmonsters_*_crash_*.mdmp" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5
if ($dumps) {
    $dumpDir = Join-Path $work "crash-dumps"
    New-Item -ItemType Directory -Force $dumpDir | Out-Null
    foreach ($d in $dumps) { Copy-Item $d.FullName $dumpDir }
    Say "  added $(@($dumps).Count) crash dump(s)"
} else {
    Say "  no crash dumps from the last week" DarkGray
}

# A short summary: versions and what is installed where.
$lines = @()
$lines += "Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
$lines += "Windows: $([Environment]::OSVersion.VersionString) ($(if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }))"
$exe = Get-Item (Join-Path $GamePath $ExeName)
$lines += "Game exe: $($exe.Length) bytes, modified $($exe.LastWriteTime)"
$lines += "Game folder: $GamePath"
$lines += "Jeode proxy (winhttp.dll): $(Test-Path (Join-Path $GamePath 'winhttp.dll'))"
$lines += "Jeode (jeode\libjeode.dll): $(Test-Path (Join-Path $GamePath 'jeode\libjeode.dll'))"
$modDir = Join-Path $GamePath "mods\msm-a11y"
if (Test-Path $modDir) {
    $lines += "Mod files:"
    foreach ($f in Get-ChildItem $modDir -File) { $lines += "  $($f.Name)  $($f.Length) bytes  $($f.LastWriteTime)" }
    $menus = Join-Path $modDir "data\menus"
    $lines += "Menu hooks: $(if (Test-Path $menus) { (Get-ChildItem $menus -Filter *.xml).Count } else { 0 }) files"
} else {
    $lines += "Mod folder missing: $modDir"
}
$lines += "Other mods: $((Get-ChildItem (Join-Path $GamePath 'mods') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'msm-a11y' } | ForEach-Object Name) -join ', ')"
$readers = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(nvda|jfw|narrator|sa|snova|zoomtext|zt)$' } | ForEach-Object Name
$lines += "Screen reader processes: $(if ($readers) { ($readers | Select-Object -Unique) -join ', ' } else { 'none found' })"
[IO.File]::WriteAllLines((Join-Path $work "summary.txt"), $lines)
Say "  added summary.txt"

if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $work "*") -DestinationPath $zip
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Say ""
Say "SAVED: $zip" Green
Say ""
Say "Attach this zip to your bug report (a GitHub issue, or send it to whoever is helping you)."
Say "It contains the mod's log, which includes text read from the game such as your in-game name,"
Say "friends' names and your friend code. Nothing has been sent anywhere."
Say ""
Say "Opening the Desktop with the zip selected..."
Start-Process explorer.exe "/select,`"$zip`""
