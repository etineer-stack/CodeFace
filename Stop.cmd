@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0helper\stop-creepy-helper.ps1"
