<#
.SYNOPSIS
    Generates the menu XML overrides for the Jeode mod from the game's own files.
.DESCRIPTION
    Every menu in <game>\data\menus gets an invisible "A11yHook" element whose onTick hands the
    live menu root to init.lua (a11y_menuTick). That gives the mod a fresh element handle for any
    screen the game opens, including ones opened from C++ that Lua never sees (bakery, context
    bar, confirmations), so Tab navigation can reach them.

    The tutorial menus also get their own hooks in their "Functions" element: onTick calls
    a11y_tutTick (banner reading) and queuePop calls a11y_tutGone.

    Output goes to jeode\msm-a11y\data\menus\. Re-run after game updates.
    With -Deploy, also copies the whole mod folder into <game>\mods\msm-a11y\.
#>
param(
    [string]$GamePath = "D:\SteamLibrary\steamapps\common\My Singing Monsters",
    [switch]$Deploy,
    # Write the overrides here instead (the installer points it at the game's mod folder).
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ModDir = Join-Path $ProjectRoot "jeode\msm-a11y"
if (-not $OutDir) { $OutDir = Join-Path $ModDir "data\menus" }
$SrcDir = Join-Path $GamePath "data\menus"
$TutorialMenus = @("tutorial", "popup_tutorial", "popup_tutorial_streamlined")
# Menus left untouched (add here if an override ever misbehaves).
$Skip = @()

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Test-Xml([string]$text) {
    try { [void][xml]$text; return $true } catch { return $false }
}

function Add-TutorialHooks([string]$xml, [string]$m) {
    $anchor = '<element name="Functions">'
    $count = ([regex]::Matches($xml, [regex]::Escape($anchor))).Count
    if ($count -ne 1) { throw "$m.xml: expected 1 Functions element, found $count" }
    $hooks = $anchor + "`r`n" +
        "`t`t<event name=`"onInit`" params=`"element`">`r`n" +
        "`t`t`tpcall(function() a11y_log(`"[tut] override loaded: $m`") end)`r`n" +
        "`t`t</event>`r`n" +
        "`t`t<event name=`"onTick`" params=`"element, dt`">`r`n" +
        "`t`t`tpcall(function() if type(a11y_tutTick) == `"function`" then a11y_tutTick(element:root(), `"$m`") end end)`r`n" +
        "`t`t</event>"
    $xml = $xml.Replace($anchor, $hooks)
    $popAnchor = '<event name="queuePop" params="element">'
    if ($xml.Contains($popAnchor)) {
        $xml = $xml.Replace($popAnchor, $popAnchor + "`r`n" +
            "`t`tpcall(function() if type(a11y_tutGone) == `"function`" then a11y_tutGone(`"$m`") end end)")
    }
    return $xml
}

# pcall-wrapped so a missing global or a bad read can never break the game's menu.
function Add-MenuHook([string]$xml, [string]$m) {
    $close = $xml.LastIndexOf("</menu>")
    if ($close -lt 0) { return $null }
    $hook = "`t<element name=`"A11yHook`">`r`n" +
        "`t`t<event name=`"onTick`" params=`"element, dt`">`r`n" +
        "`t`t`tpcall(function() if type(a11y_menuTick) == `"function`" then a11y_menuTick(element:root(), `"$m`") end end)`r`n" +
        "`t`t</event>`r`n" +
        "`t</element>`r`n"
    return $xml.Substring(0, $close) + $hook + $xml.Substring($close)
}

$done = 0; $skipped = @()
foreach ($file in Get-ChildItem $SrcDir -Filter *.xml) {
    $m = $file.BaseName
    if ($Skip -contains $m) { $skipped += "$m (skip list)"; continue }
    $xml = [System.IO.File]::ReadAllText($file.FullName)
    if ($xml.Length -gt 0 -and $xml[0] -eq [char]0xFEFF) { $xml = $xml.Substring(1) }
    if (-not (Test-Xml $xml)) { $skipped += "$m (original not well-formed)"; continue }
    if ($xml.Contains('name="A11yHook"')) { throw "$m.xml already contains A11yHook - is GamePath pointing at an override?" }

    if ($TutorialMenus -contains $m) { $xml = Add-TutorialHooks $xml $m }
    $out = Add-MenuHook $xml $m
    if (-not $out) { $skipped += "$m (no </menu>)"; continue }
    if (-not (Test-Xml $out)) { $skipped += "$m (result not well-formed)"; continue }

    [System.IO.File]::WriteAllText((Join-Path $OutDir "$m.xml"), $out, $utf8NoBom)
    $done++
}

Write-Host "generated $done menu overrides in $OutDir"
foreach ($s in $skipped) { Write-Host "  skipped: $s" }

if ($Deploy) {
    $dest = Join-Path $GamePath "mods\msm-a11y"
    $destMenus = Join-Path $dest "data\menus"
    if (Test-Path $destMenus) { Remove-Item -Recurse -Force $destMenus }
    New-Item -ItemType Directory -Force $dest | Out-Null
    # Per item, so a DLL locked by the running game doesn't stop the rest.
    foreach ($item in Get-ChildItem $ModDir) {
        try { Copy-Item -Recurse -Force $item.FullName $dest -ErrorAction Stop }
        catch { Write-Warning "not copied (game running?): $($item.Name)" }
    }
    Write-Host "deployed to $dest"
}
