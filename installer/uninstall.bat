@echo off
REM Removes My Singing Monsters Access. Double-click to run.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Uninstall.ps1" %* & echo. & pause & exit /b
