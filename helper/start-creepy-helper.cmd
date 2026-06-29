@echo off
setlocal
cd /d "%~dp0"
set "APPROOT=%~dp0.."
set "LOG=%~dp0helper-start.log"
echo [%date% %time%] Starting Lively helper from %~dp0 > "%LOG%"
start "Lively CodeFace helper" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0creepy-helper.ps1" -AppRootOverride "%APPROOT%"
