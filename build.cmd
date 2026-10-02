@echo off
REM Builds bnet-switcher.exe without changing your PowerShell execution policy.
REM Windows blocks .ps1 scripts by default ("running scripts is disabled on this
REM system"); -ExecutionPolicy Bypass applies to this one run only. No admin needed.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
echo.
pause
