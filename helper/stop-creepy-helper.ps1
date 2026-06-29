$ErrorActionPreference = "SilentlyContinue"
$helperPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "creepy-helper.ps1"))
$current = $PID
$parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$current").ParentProcessId
Get-CimInstance Win32_Process |
  Where-Object {
    $_.ProcessId -ne $current -and
    $_.ProcessId -ne $parent -and
    $_.CommandLine -and
    $_.CommandLine.IndexOf($helperPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
