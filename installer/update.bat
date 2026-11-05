@echo off
REM Updates My Singing Monsters Access to the newest release. Double-click to run.
REM One line on purpose: the updater replaces this file while it runs, and cmd
REM reads a batch file as it goes, so nothing may come after this line.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Update.ps1" %* & echo. & pause & exit /b
