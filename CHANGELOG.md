# Changelog

What changed in each version of My Singing Monsters Access, newest first. Changes that are done but not yet in a release are listed under Unreleased.

## Unreleased

### Improved

- The countdown button at the bottom of the main screen (for example "1d 20h") is a limited-time shop offer. It now says "Offer", with the offer's name when the game provides one, and the time left.

### Fixed

- Control+Shift+W said "Collect All is on the bar" even before the game unlocks Collect All. It now says whether Collect All is there, recharging, or not unlocked yet, and if not, how to collect from each monster instead.
- The Goals screen said "Nothing to navigate" (the game changed how goals are built in 5.7.4). Every goal now has a "Show me" item that says the goal, its progress and its reward, and Collect buttons say which goal and what you get, for example "Collect: Breed a Fwog and Potbelly together. Reward: 50 coins".

## 0.1.5-alpha - 2026-11-05

### Fixed

- On the main screen, Tab often went silent or skipped things (since 0.1.4-alpha). The new Encore button label hit an error that stopped the whole list. The Encore event screen's points line had the same error.

## 0.1.4-alpha - 2026-11-05

### Fixed

- The Map showed only Close and Help most of the time (since 0.1.3-alpha): the islands are back. The crash fix in 0.1.3-alpha expected every screen to refresh every frame, and the map doesn't.
- The "Welcome to" screen after getting a new island had no way to continue. It now has a Continue item, and Escape continues too.
- After placing a decoration you were stuck on a screen with only Show Grid. The game selects the new decoration and opens its Decoration Size panel; Tab now offers the decoration's own buttons (Info, Sell, Move, Buy more) plus Show Grid, and Escape deselects it and closes the panel.
- Since the game's 5.7.4 update, the mod couldn't tell where any object on the island was, so placing said "No objects to jump to" and never described where you were next to things. It finds that part of the game again, in a way that should survive small game updates.
- When an arrow key didn't move the object being placed, every later arrow press missed too. Now it says "Did not move", and the next press re-centres on the object first.

### Improved

- Map: picking an island reads its details (cost, requirements, what you have collected) and puts focus on GO, so Enter travels there.
- Encore: the event screen reads the event's name, theme, how points are earned (for example "Every 15 minutes of Incubation time earns 1 point"), your points and the time left. The Encore button on the main screen says your points and time left too.
- "How it works" screens (Encore, sticker album) read their numbered steps.
- Map: the arrow buttons are called Previous island and Next island, GO says which island it goes to, and the alert buttons at the top have proper names instead of "SeasonalAlert".

## 0.1.3-alpha - 2026-11-05

### Fixed

- Pressing Tab right after opening the Market (or anything else that switches screens) no longer freezes and crashes the game.
- The "You received:" screen after collecting rewards now reads what you got, for example "You received: 5 Minigame Tokens, 2 Common Sticker Packs", instead of only "You received:".
- Screens that say "Click to continue" (rewards, card packs) now have a Continue item you can Tab to. Before, there was nothing to press and no way out. Escape and Backspace also continue on those screens.
- The tutorial step at the Nursery now hatches the egg when you press Enter on it, instead of a click that could miss.
- Tutorial steps about buying something (such as "Buy a Noggin egg") now point at the Market, not the Breeding Structure.
- Clicking on an island object no longer sounds like it surely worked: it says "If nothing happened, the click missed."

### Improved

- Breeding: the two monster lists are announced as "Monster 1 list" and "Monster 2 list" when you Tab into them, and Left bracket and Right bracket jump between them.
- Breeding: the monster you picked says "selected", and monsters in the other list say who they would breed with, for example "Glob, Toe Jammer, breed with Noggy1".
- Breeding: after each pick you hear what is chosen and what to do next, for example "Breeding Noggy1 with Glob. Now press Breed."

## 0.1.2-alpha - 2026-11-05

### Fixed

- Two crashes: one when a screen closed right after pressing Enter (Market, Visit, buying from a confirmation), and one while the game was loading the first tutorial step.

### Added

- `debug.bat`: zips the mod's log, Jeode's log, recent crash reports and a short summary onto your Desktop, ready to attach to a bug report. Nothing is sent anywhere.

## 0.1.1-alpha - 2026-11-05

### Added

- `update.bat`: checks GitHub for the newest version, downloads it over the folder you run it from, and installs it.

### Changed

- Every release is now marked Latest, so the "latest release" link always gets the newest build.
- The README no longer tells you to start your screen reader, and spells out Left bracket and Right bracket in the keys table.

## 0.1.0-alpha - 2026-11-05

First public release.

- Speech through Prism, which works with NVDA, JAWS, System Access, Narrator, or Windows' own voice when no screen reader is running.
- Tab, Shift+Tab and Enter work on menus, dialogs, the bottom bar, the top counters and the island's objects; Escape and Backspace go back.
- Island objects grouped into Buttons, Buildings, Monsters, Decorations, and Trees and rocks, with Left bracket and Right bracket to switch groups.
- Placing objects from the keyboard: arrow keys, nearby free spots with Comma and Period, and landmarks with the brackets.
- Status (Control+Shift+A), What now (Control+Shift+W), Places (Control+Shift+M), the island object list (Control+Shift+O) and the tutorial keys (Control+Shift+T and Control+Shift+Enter).
- Labels for the Friends screen, the Inbox, the profile editor, the Book of Monsters and its filters, and the Options screen.
- Pressing No on a Yes/No question no longer presses Yes.
- The Options screen's Screen Size and Language lists show only their own choices and no longer stack on top of each other.
- `install.bat` finds the game, installs the Jeode mod loader if needed, copies the mod and builds its menu hooks from your own game files; `uninstall.bat` removes it.
