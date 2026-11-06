# My Singing Monsters Access

My Singing Monsters Access is a mod that makes the PC (Steam) version of My Singing Monsters playable with a screen reader such as NVDA or JAWS. Menus, buttons, dialogs, your island's objects and placing things on the grid are all reachable from the keyboard and spoken aloud.

> [!WARNING]
> **This is early, experimental software. Read this before installing.**
>
> - **It is an unofficial fan mod.** It is not made, endorsed or supported by Big Blue Bubble. Do not contact them for help with it.
> - **My Singing Monsters is an online game tied to your account.** Modding it may break the game's terms of service. Using any mod could, in the worst case, get your account flagged or banned. **You use this entirely at your own risk.**
> - **Expect bugs.** Some screens are not labelled yet, some announcements are wrong, and the mod can press the wrong button. In testing it has pressed "Yes" when "No" was chosen. That one is fixed, but there may be others like it, so **be careful on any screen that spends diamonds or real money.**
> - **The game can crash.** If it does, restart it. Your progress is saved on the game's servers, not by the mod.
> - **Game updates can break the mod.** After every game update, run `install.bat` again. If the mod then misbehaves, uninstall it until a fixed version is out.
> - It is provided as is, with no warranty of any kind.
>
> If any of that is not OK with you, do not install it.

## What you need

- **Windows** (10 or 11) and **My Singing Monsters from Steam**.
- **A screen reader.** NVDA is recommended and the one it is tested with. JAWS, System Access and Windows Narrator should also work. If none is running, Windows' built-in voice (SAPI) is used.
- **An internet connection while installing**, so the installer can download the Jeode mod loader if you don't have it.

You do **not** need any programming tools. Everything is already built.

## Installing (the easy way)

1. Go to the [Releases page](../../releases/latest) and download the zip file named `msm-a11y-<version>.zip` (under "Assets").
2. **Extract the whole zip** to a folder, for example your Desktop. (Right-click the zip, choose "Extract All", then "Extract".) Don't run anything from inside the zip.
3. **Close My Singing Monsters** if it is running.
4. Open the extracted folder and run **`install.bat`** (double-click it, or select it and press Enter).
5. A window opens and talks you through it. It will:
   - find your game folder (if it can't, it tells you how to find it and asks you to paste it),
   - offer to download and install **Jeode**, the mod loader this mod runs on (answer `y`),
   - copy the mod into the game's `mods` folder,
   - build the mod's menu hooks from your own copy of the game.
6. When it says **INSTALLED**, press any key to close the window.
7. Start My Singing Monsters from Steam as usual. While it loads you should hear "My Singing Monsters accessibility mod loaded via Jeode".

The installer is safe to run more than once. Running it again is how you **repair the mod after a game update**.

### Updating

Run **`update.bat`** from the same folder you installed from. It checks GitHub for the newest version and, if there is one:

- downloads it and copies it over that folder, so that folder's `install.bat` installs the new version from then on,
- installs it into the game straight away.

If you already have the newest version, it says so and changes nothing. (Downloading the new zip and running its `install.bat` also works.)

What changed in each version is in the [changelog](CHANGELOG.md), which is also in the zip.

### If Windows or your antivirus complains

- **"Windows protected your PC" (SmartScreen):** choose "More info", then "Run anyway". The scripts are plain text you can open in Notepad and read.
- **Antivirus removes Jeode** (Windows Defender, Avast and AVG are known to do this wrongly): add your My Singing Monsters folder as an exclusion in the antivirus, then run `install.bat` again. This is a known false alarm with Jeode, see [Jeode's page](https://github.com/Paficent/jeode).

## Installing by hand

Only needed if `install.bat` doesn't work for you.

1. **Find your game folder.** In Steam, right-click My Singing Monsters, choose Manage, then Browse local files. It's the folder that contains `MySingingMonsters.exe`, usually `C:\Program Files (x86)\Steam\steamapps\common\My Singing Monsters`.
2. **Install Jeode.** From [Jeode's latest release](https://github.com/Paficent/jeode/releases/latest), either run `jeode-installer.exe`, or download `winhttp.dll` and `libjeode.dll` and place them like this:
   ```
   My Singing Monsters\
       MySingingMonsters.exe
       winhttp.dll
       jeode\
           libjeode.dll
   ```
3. **Copy the mod.** From the extracted zip, copy the folder `mod\msm-a11y` into the game's `mods` folder (create `mods` if it isn't there), so you end up with `My Singing Monsters\mods\msm-a11y\a11y.dll`.
4. **Build the menu hooks.** Open PowerShell in the extracted zip's `installer` folder and run (with your own game path):
   ```
   powershell -ExecutionPolicy Bypass -File .\Build-MenuOverrides.ps1 -GamePath "C:\Program Files (x86)\Steam\steamapps\common\My Singing Monsters" -OutDir "C:\Program Files (x86)\Steam\steamapps\common\My Singing Monsters\mods\msm-a11y\data\menus"
   ```
   Without this step the mod still talks, but most screens can't be navigated.

## Keys

| Key | What it does |
| --- | --- |
| Tab / Shift+Tab | Next / previous item on the current screen |
| Enter | Press the current item |
| Escape or Backspace | Go back: close the screen, cancel, answer No, or deselect. The game's own Escape is tried first. |
| Left bracket and Right bracket | On the island: switch between groups (Buttons, Buildings, Monsters, Decorations, Trees and rocks). While placing an object: jump between nearby landmarks. |
| Comma and Period | While placing an object: step through the free spots near where you are. |
| Arrow keys | While placing an object: move it one tile. |
| Control+Shift+A | Status: coins, diamonds, food, level and so on. |
| Control+Shift+W | What now: things that are ready and your current goals. |
| Control+Shift+M | Places: Market, Book of Monsters, Map, Goals, Friends, Mail, Options. |
| Control+Shift+O | A list of everything on your island. |
| Control+Shift+T | Repeat the current tutorial step. |
| Control+Shift+Enter | Continue the tutorial. |
| Control+Shift+D | Write a diagnostic snapshot of the current screen to the log (for bug reports). |

## Reporting a problem

1. If a screen reads badly, press **Control+Shift+D** on that screen first. That snapshot is what makes it possible to label a screen.
2. If the game crashed or froze, close it (or let it close) first.
3. Run **`debug.bat`** from the folder you installed from. It puts a zip named `msm-access-debug-<date>.zip` on your Desktop and opens the Desktop with it selected. The zip holds the mod's log, Jeode's log, recent crash reports and a short summary of versions. Nothing is sent anywhere.
4. [Open an issue](../../issues) and attach the zip. Say what you did, what you expected, and what happened instead.

The log includes text read from the game, such as your in-game name, friends' names and your friend code. If you'd rather not post that publicly, send the zip privately instead.

## Uninstalling

Run **`uninstall.bat`** from the folder you installed from. It removes the mod and asks whether to remove Jeode as well (say no if you use other Jeode mods). To do it by hand, delete `My Singing Monsters\mods\msm-a11y`, and for Jeode also `winhttp.dll` and the `jeode` folder.

## How it works

- [Jeode](https://github.com/Paficent/jeode) loads the mod into the game. The mod is a Lua script (`init.lua`) plus a small native DLL (`a11y.dll`) for keyboard input and speech.
- Speech goes through [Prism](https://github.com/ethindp/prism), which talks to whichever screen reader is running.
- The game's screens are defined in menu files. At install time the installer copies each of your game's menu files into the mod with one invisible hook added. That's how the mod sees every screen, including ones the game opens internally. Because these are built from your own game files, the mod doesn't redistribute any of the game's files.

## Building from source

Only needed for development. Players should use the release zip.

Requirements: Visual Studio 2022 (or Build Tools) with "Desktop development with C++", plus Git. CMake and Ninja come with Visual Studio.

```
scripts\Build-Prism.bat      (once: builds a 32-bit prism.dll into native\prism)
scripts\Build-Jeode.bat      (builds a11y.dll into jeode\msm-a11y)
powershell -File scripts\Build-MenuOverrides.ps1 -GamePath "<game folder>" -Deploy
powershell -File scripts\Make-Release.ps1 -Version 0.1.0   (optional: the player zip)
```

Pushing a tag such as `v0.1.0` runs the GitHub Actions workflow, which builds everything and attaches the zip to a new release marked Latest.

## Credits

- [Jeode](https://github.com/Paficent/jeode) by Paficent (Boost Software License 1.0), the mod loader.
- [Prism](https://github.com/ethindp/prism) by Ethin Probst (MPL 2.0), screen reader output.
- [MinHook](https://github.com/TsudaKageyu/minhook) (BSD 2-Clause) and [Lua 5.1](https://www.lua.org/) (MIT).

My Singing Monsters is a trademark of Big Blue Bubble Inc. This project is not affiliated with them.
