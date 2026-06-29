@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Command "$startup=[Environment]::GetFolderPath('Startup'); $shortcutPath=Join-Path $startup 'CodeFace Lively Helper.lnk'; if(Test-Path -LiteralPath $shortcutPath){ Remove-Item -LiteralPath $shortcutPath -Force; Write-Host 'Removed startup shortcut:' $shortcutPath } else { Write-Host 'Startup shortcut was not installed.' }"
