@echo off
REM Installs My Singing Monsters Access. Double-click to run.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Install.ps1" %* & echo. & pause & exit /b
