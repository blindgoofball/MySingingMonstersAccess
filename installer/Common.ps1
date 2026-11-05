# Shared by Install.ps1, Update.ps1 and Uninstall.ps1 (dot-sourced).

$ExeName = "MySingingMonsters.exe"
$RepoApi = "https://api.github.com/repos/tunmi13productions/MySingingMonstersAccess"

function Say([string]$text, [string]$color = "White") { Write-Host $text -ForegroundColor $color }

# Every Steam library folder: from the registry, libraryfolders.vdf, and the
# usual "SteamLibrary" folder on each drive.
function Get-SteamLibraries {
    $libs = @()
    $steamRoots = @()
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in @("SteamPath", "InstallPath")) {
                if ($item.$name) { $steamRoots += ($item.$name -replace "/", "\") }
            }
        } catch {}
    }
    $steamRoots += "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam"
    foreach ($steam in ($steamRoots | Select-Object -Unique)) {
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            $content = Get-Content $vdf -Raw
            foreach ($m in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $libs += (Join-Path $drive.Root "SteamLibrary"), (Join-Path $drive.Root "Steam")
    }
    return $libs | Select-Object -Unique
}

function Find-Game {
    foreach ($lib in Get-SteamLibraries) {
        $p = Join-Path $lib "steamapps\common\My Singing Monsters"
        if (Test-Path (Join-Path $p $ExeName)) { return $p }
    }
    return $null
}

# The game folder: the one given, else found automatically, else asked for.
# Returns $null if no folder with the game's exe was given.
function Resolve-GamePath([string]$GamePath) {
    if (-not $GamePath) {
        Say "Looking for My Singing Monsters in your Steam libraries..."
        $GamePath = Find-Game
        if ($GamePath) {
            Say "Found it: $GamePath" Green
        } else {
            Say "Could not find the game automatically." Yellow
            Say "In Steam: right-click My Singing Monsters, Manage, Browse local files. Copy that folder's path from the address bar."
            $GamePath = (Read-Host "Paste the game folder path and press Enter").Trim().Trim('"').Trim("'")
        }
    }
    if (-not $GamePath -or -not (Test-Path (Join-Path $GamePath $ExeName))) { return $null }
    return $GamePath
}

function Wait-GameClosed {
    while (Get-Process -Name "MySingingMonsters" -ErrorAction SilentlyContinue) {
        Say "My Singing Monsters is running. Close the game, then press Enter to continue." Yellow
        [void](Read-Host)
    }
}
