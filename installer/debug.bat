@echo off
REM Zips the logs and crash dumps needed for a bug report onto the Desktop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Collect-Logs.ps1" %* & echo. & pause & exit /b
