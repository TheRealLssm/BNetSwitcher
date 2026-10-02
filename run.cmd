@echo off
REM Starts the switcher straight from the script - no build, no exe.
REM -ExecutionPolicy Bypass applies to this one run only. No admin needed.
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0bnet-switcher-gui.ps1"
