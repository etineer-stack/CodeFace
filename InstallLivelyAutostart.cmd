@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$root=(Resolve-Path -LiteralPath '%~dp0').Path; $startup=[Environment]::GetFolderPath('Startup'); $shortcutPath=Join-Path $startup 'CodeFace Lively Helper.lnk'; $target=Join-Path $root 'StartForLively.cmd'; $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut($shortcutPath); $shortcut.TargetPath=$target; $shortcut.WorkingDirectory=$root; $shortcut.WindowStyle=7; $shortcut.Description='Starts the local CodeFace helper for Lively Wallpaper'; $shortcut.Save(); Write-Host 'Installed startup shortcut:' $shortcutPath"
call "%~dp0StartForLively.cmd"
