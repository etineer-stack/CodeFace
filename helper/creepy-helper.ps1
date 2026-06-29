param([string]$AppRootOverride = '')

$ErrorActionPreference = "Stop"

$Port = 17346
$MaxFilesToInspect = 2500
$MaxBytesPerFile = 9000
$RecentReplyLimit = 22
$RescanIntervalMinutes = 10
$AppRoot = if ($AppRootOverride) { [IO.Path]::GetFullPath($AppRootOverride) } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..")) }
$ScanReportPath = Join-Path $AppRoot "last-scan-report.txt"
$MemoryPath = Join-Path $AppRoot "codeface-memory.json"
$ExcludedFolderNames = @("CodeFace", "Codex", ".codex", ".git", ".chatGPT", "node_modules", "backups", "prototypes")
$ExtensionsToRead = @(".txt", ".md", ".csv", ".log", ".json", ".xml", ".html", ".htm", ".ini", ".config", ".rtf")

$KnownFirstNames = @(
  "Aaron","Abigail","Adam","Adrian","Aisha","Alex","Alexander","Alice","Amanda","Amelia","Amy","Andrea",
  "Andrew","Anna","Anthony","Arthur","Ashley","Benjamin","Beth","Brandon","Brian","Camille","Carlos",
  "Caroline","Charlotte","Chloe","Chris","Christopher","Claire","Daniel","David","Diana","Dominic","Dylan",
  "Elena","Eli","Elise","Elizabeth","Ella","Emily","Emma","Eric","Ethan","Eva","Felix","Gabriel","George",
  "Grace","Hannah","Harry","Henry","Isabella","Jack","Jacob","James","Jasmine","Jason","Jean","Jennifer",
  "Jessica","John","Jon","Jonathan","Joseph","Josh","Joshua","Julia","Julien","Julie","Justin","Karen",
  "Kate","Kevin","Laura","Leo","Liam","Lily","Louis","Lucas","Lucy","Luke","Marc","Maria","Marie","Mark",
  "Martin","Matthew","Maya","Michael","Monique","Etienne","Michelle","Nathan","Nicolas","Nicole","Noah","Oliver","Olivia",
  "Omar","Oscar","Patrick","Paul","Philip","Phillip","Pierre","Rachel","Rebecca","Ryan","Sam","Samuel",
  "Sarah","Sophie","Thomas","Tom","Victor","William","Yasmine","Zoe"
)

$NameSet = @{}
foreach ($n in $KnownFirstNames) { $NameSet[$n.ToUpperInvariant()] = $true }

$Script:Knowledge = @{ Names=@(); Keywords=@(); Files=@(); NameSources=@{}; NameContexts=@{} }
$Script:Memory = $null
$Script:RecentReplies = New-Object System.Collections.Generic.Queue[string]
$Script:Turn = 0
$Script:NextScanAt = [DateTime]::MinValue

$WindowApiSource = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodeFaceWindowApi {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);
  public static bool IsCloaked(IntPtr h) { int v = 0; try { if (DwmGetWindowAttribute(h, 14, out v, 4) == 0) return v != 0; } catch {} return false; }
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  public static bool IsToolWindow(IntPtr h) { try { return (GetWindowLong(h, -20) & 0x80) != 0; } catch { return false; } }   // WS_EX_TOOLWINDOW
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
try { Add-Type -TypeDefinition $WindowApiSource -ErrorAction SilentlyContinue } catch {}

function Get-WindowTextSafe {
  param([IntPtr]$Handle)
  $len = [CodeFaceWindowApi]::GetWindowTextLength($Handle)
  if ($len -le 0) { return "" }
  $sb = New-Object Text.StringBuilder ($len + 1)
  [void][CodeFaceWindowApi]::GetWindowText($Handle, $sb, $sb.Capacity)
  return $sb.ToString()
}

function Get-WindowClassSafe {
  param([IntPtr]$Handle)
  $sb = New-Object Text.StringBuilder 256
  [void][CodeFaceWindowApi]::GetClassName($Handle, $sb, $sb.Capacity)
  return $sb.ToString()
}

function Get-WindowCoverageSnapshot {
  param([int]$Width = 0, [int]$Height = 0, [int]$FaceL = 0, [int]$FaceT = 0, [int]$FaceR = 0, [int]$FaceB = 0)
  if ($Width -le 0) { $Width = 1920 }
  if ($Height -le 0) { $Height = 1080 }
  $cols = 36; $rows = 20
  $covered = New-Object bool[] ($cols * $rows)
  $shell = [CodeFaceWindowApi]::GetShellWindow()
  $ignoredClasses = @{ 'Progman'=$true; 'WorkerW'=$true; 'Shell_TrayWnd'=$true; 'DV2ControlHost'=$true }
  $windows = New-Object System.Collections.Generic.List[object]
  $callback = [CodeFaceWindowApi+EnumWindowsProc]{
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    if ($hWnd -eq $shell) { return $true }
    if (-not [CodeFaceWindowApi]::IsWindowVisible($hWnd)) { return $true }
    if ([CodeFaceWindowApi]::IsIconic($hWnd)) { return $true }
    if ([CodeFaceWindowApi]::IsCloaked($hWnd)) { return $true }     # other virtual desktop / cloaked UWP
    if ([CodeFaceWindowApi]::IsToolWindow($hWnd)) { return $true }  # transparent overlays (NVIDIA, etc.)
    $className = Get-WindowClassSafe $hWnd
    if ($ignoredClasses.ContainsKey($className)) { return $true }
    $title = Get-WindowTextSafe $hWnd
    if ([string]::IsNullOrWhiteSpace($title) -and $className -match '^(Windows.UI.Core.CoreWindow|ApplicationFrameWindow)$') { return $true }
    $rect = New-Object CodeFaceWindowApi+RECT
    if (-not [CodeFaceWindowApi]::GetWindowRect($hWnd, [ref]$rect)) { return $true }
    $l = [Math]::Max(0, [Math]::Min($Width, $rect.Left))
    $t = [Math]::Max(0, [Math]::Min($Height, $rect.Top))
    $r = [Math]::Max(0, [Math]::Min($Width, $rect.Right))
    $b = [Math]::Max(0, [Math]::Min($Height, $rect.Bottom))
    if (($r - $l) -lt 80 -or ($b - $t) -lt 80) { return $true }
    $windows.Add([pscustomobject]@{ left=$l; top=$t; right=$r; bottom=$b; title=$title; class=$className }) | Out-Null
    return $true
  }
  [void][CodeFaceWindowApi]::EnumWindows($callback, [IntPtr]::Zero)

  foreach ($w in $windows) {
    $c1 = [Math]::Max(0, [Math]::Floor($w.left / $Width * $cols))
    $c2 = [Math]::Min($cols - 1, [Math]::Ceiling($w.right / $Width * $cols) - 1)
    $r1 = [Math]::Max(0, [Math]::Floor($w.top / $Height * $rows))
    $r2 = [Math]::Min($rows - 1, [Math]::Ceiling($w.bottom / $Height * $rows) - 1)
    for ($yy = $r1; $yy -le $r2; $yy++) { for ($xx = $c1; $xx -le $c2; $xx++) { $covered[$yy * $cols + $xx] = $true } }
  }

  $coveredCount = 0
  foreach ($cell in $covered) { if ($cell) { $coveredCount++ } }
  $best = @{ area=0; x=0.5; y=0.5; w=1.0; h=1.0 }
  $visited = New-Object bool[] ($cols * $rows)
  for ($yy = 0; $yy -lt $rows; $yy++) {
    for ($xx = 0; $xx -lt $cols; $xx++) {
      $idx = $yy * $cols + $xx
      if ($covered[$idx] -or $visited[$idx]) { continue }
      $q = New-Object System.Collections.Generic.Queue[object]
      $q.Enqueue(@($xx,$yy)); $visited[$idx] = $true
      $minX=$xx; $maxX=$xx; $minY=$yy; $maxY=$yy; $area=0
      while ($q.Count -gt 0) {
        $pt = $q.Dequeue(); $cx=[int]$pt[0]; $cy=[int]$pt[1]; $area++
        if ($cx -lt $minX) { $minX=$cx }; if ($cx -gt $maxX) { $maxX=$cx }
        if ($cy -lt $minY) { $minY=$cy }; if ($cy -gt $maxY) { $maxY=$cy }
        foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) {
          $nx=$cx+[int]$d[0]; $ny=$cy+[int]$d[1]
          if ($nx -lt 0 -or $nx -ge $cols -or $ny -lt 0 -or $ny -ge $rows) { continue }
          $ni=$ny*$cols+$nx
          if (-not $covered[$ni] -and -not $visited[$ni]) { $visited[$ni]=$true; $q.Enqueue(@($nx,$ny)) }
        }
      }
      if ($area -gt $best.area) {
        $best = @{ area=$area; x=(($minX+$maxX+1)/2)/$cols; y=(($minY+$maxY+1)/2)/$rows; w=(($maxX-$minX+1)/$cols); h=(($maxY-$minY+1)/$rows) }
      }
    }
  }

  $ratio = if (($cols*$rows) -gt 0) { [Math]::Round($coveredCount / ($cols * $rows), 3) } else { 0 }

  # Coverage of just the face's bounding box (how blocked the smiley itself is).
  $faceCov = 0.0
  if ($FaceR -gt $FaceL -and $FaceB -gt $FaceT) {
    $fc1 = [Math]::Max(0, [Math]::Floor($FaceL / $Width * $cols))
    $fc2 = [Math]::Min($cols - 1, [Math]::Ceiling($FaceR / $Width * $cols) - 1)
    $fr1 = [Math]::Max(0, [Math]::Floor($FaceT / $Height * $rows))
    $fr2 = [Math]::Min($rows - 1, [Math]::Ceiling($FaceB / $Height * $rows) - 1)
    $ftot = 0; $fcov = 0
    for ($yy = $fr1; $yy -le $fr2; $yy++) { for ($xx = $fc1; $xx -le $fc2; $xx++) { $ftot++; if ($covered[$yy * $cols + $xx]) { $fcov++ } } }
    if ($ftot -gt 0) { $faceCov = [Math]::Round($fcov / $ftot, 3) }
  }
  return [pscustomobject]@{ type='windowCoverage'; coverage=$ratio; faceCoverage=$faceCov; targetX=[Math]::Round($best.x,4); targetY=[Math]::Round($best.y,4); gapW=[Math]::Round($best.w,4); gapH=[Math]::Round($best.h,4); windowCount=$windows.Count }
}

function New-Memory {
  return [pscustomobject]@{
    UserName = ""
    Facts = @()
    LastMessages = @()
    SuppressedTopics = @()
    Mood = "curious"
    CurrentTopic = ""
    PreviousTopic = ""
    PendingQuestion = ""
    Associations = @()
    Created = (Get-Date).ToString("s")
    Updated = (Get-Date).ToString("s")
  }
}

function Load-Memory {
  try {
    if (Test-Path -LiteralPath $MemoryPath) {
      $m = Get-Content -LiteralPath $MemoryPath -Raw | ConvertFrom-Json
      if (-not $m.Facts) { $m | Add-Member -NotePropertyName Facts -NotePropertyValue @() }
      if (-not $m.LastMessages) { $m | Add-Member -NotePropertyName LastMessages -NotePropertyValue @() }
      if (-not $m.SuppressedTopics) { $m | Add-Member -NotePropertyName SuppressedTopics -NotePropertyValue @() }
      if (-not $m.Mood) { $m | Add-Member -NotePropertyName Mood -NotePropertyValue "curious" }
      if (-not $m.CurrentTopic) { $m | Add-Member -NotePropertyName CurrentTopic -NotePropertyValue "" }
      if (-not $m.PreviousTopic) { $m | Add-Member -NotePropertyName PreviousTopic -NotePropertyValue "" }
      if (-not $m.PendingQuestion) { $m | Add-Member -NotePropertyName PendingQuestion -NotePropertyValue "" }
      if (-not $m.Associations) { $m | Add-Member -NotePropertyName Associations -NotePropertyValue @() }
      return $m
    }
  } catch {}
  return New-Memory
}

function Save-Memory {
  try {
    $Script:Memory.Updated = (Get-Date).ToString("s")
    $Script:Memory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $MemoryPath -Encoding UTF8
  } catch {}
}


function Normalize-Topic {
  param([string]$Topic)
  if ([string]::IsNullOrWhiteSpace($Topic)) { return "" }
  $clean = ($Topic -replace "(?i)^(about|the|a|an|that|this|please)\s+", "")
  $clean = ($clean -replace "[^A-Za-zÀ-ÿ0-9'\- ]", " ") -replace "\s+", " "
  return $clean.Trim().ToUpperInvariant()
}

function Test-IsSuppressedTopic {
  param([string]$Text)
  if (-not $Script:Memory -or -not $Script:Memory.SuppressedTopics -or [string]::IsNullOrWhiteSpace($Text)) { return $false }
  $upper = $Text.ToUpperInvariant()
  foreach ($topic in @($Script:Memory.SuppressedTopics)) {
    if ($topic -and $upper.Contains([string]$topic)) { return $true }
  }
  return $false
}

function Add-SuppressedTopic {
  param([string]$Topic)
  $topicKey = Normalize-Topic $Topic
  if (-not $topicKey) { return $null }
  $topics = @($Script:Memory.SuppressedTopics)
  if ($topics -notcontains $topicKey) { $topics += $topicKey }
  $Script:Memory.SuppressedTopics = @($topics | Select-Object -Unique)
  $Script:Memory.Facts = @(@($Script:Memory.Facts) | Where-Object { -not (($_.ToString()).ToUpperInvariant().Contains($topicKey)) })
  $Script:Memory.LastMessages = @(@($Script:Memory.LastMessages) | Where-Object { -not (($_.text.ToString()).ToUpperInvariant().Contains($topicKey)) })
  Save-Memory
  return $topicKey
}

function Remove-SuppressedTopic {
  param([string]$Topic)
  $topicKey = Normalize-Topic $Topic
  if (-not $topicKey) { return $null }
  $Script:Memory.SuppressedTopics = @(@($Script:Memory.SuppressedTopics) | Where-Object { $_ -ne $topicKey })
  Save-Memory
  return $topicKey
}

function Add-MemoryFact {
  param([string]$Fact)
  if ([string]::IsNullOrWhiteSpace($Fact)) { return }
  $facts = @($Script:Memory.Facts)
  if ($facts -notcontains $Fact) {
    $facts += $Fact
    $Script:Memory.Facts = @($facts | Select-Object -Last 30)
    Save-Memory
  }
}

function Remember-UserMessage {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) { return }
  $msgs = @($Script:Memory.LastMessages)
  $msgs += ([pscustomobject]@{ at=(Get-Date).ToString("s"); text=$Message })
  $Script:Memory.LastMessages = @($msgs | Select-Object -Last 20)
  Save-Memory
}

function Learn-FromMessage {
  param([string]$Message)
  if (-not $Message) { return $null }
  $m = [regex]::Match($Message, "(?i)\b(?:i am|i'm|my name is|call me)\s+([A-Z][A-Za-zÀ-ÿ'\-]{1,24})\b")
  if ($m.Success) {
    $name = $m.Groups[1].Value.Trim(" .'`"")
    if ($name) {
      $Script:Memory.UserName = $name
      Add-MemoryFact "USER_NAME=$name"
      Save-Memory
      return $name
    }
  }
  $likes = [regex]::Match($Message, "(?i)\bI\s+(?:like|love|hate|miss|remember)\s+(.{3,48})")
  if ($likes.Success) { Add-MemoryFact (("USER SAID: " + $likes.Groups[1].Value.Trim()) -replace "\s+", " ") }
  return $null
}

function Get-ScanRoots {
  $roots = @()
  $docs = [Environment]::GetFolderPath("MyDocuments")
  if ($docs -and (Test-Path -LiteralPath $docs)) { $roots += $docs }
  $downloads = $null
  try { $downloads = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -Name "{374DE290-123F-4565-9164-39C4925E467B}" -ErrorAction Stop)."{374DE290-123F-4565-9164-39C4925E467B}" } catch {}
  if (-not $downloads -or -not (Test-Path -LiteralPath $downloads)) { $downloads = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads" }
  if ($downloads -and (Test-Path -LiteralPath $downloads)) { $roots += $downloads }
  return @($roots | Select-Object -Unique)
}

function Test-IsExcludedFile {
  param([IO.FileInfo]$File)
  $fullName = [IO.Path]::GetFullPath($File.FullName)
  if ($fullName.StartsWith($AppRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  $dirInfo = $File.Directory
  while ($dirInfo) {
    if ($ExcludedFolderNames -contains $dirInfo.Name) { return $true }
    $dirInfo = $dirInfo.Parent
  }
  return $false
}

function Add-Token {
  param([hashtable]$Bucket, [string]$Token)
  if ([string]::IsNullOrWhiteSpace($Token)) { return }
  $clean = $Token.Trim().ToUpperInvariant()
  if ($clean.Length -lt 3 -or $clean.Length -gt 24) { return }
  if ($clean -match "^\d+$") { return }
  if ($clean -in @("THE","AND","FOR","WITH","FROM","THIS","THAT","YOUR","YOU","ARE","WAS","WERE","PDF","DOC","DOCX","TXT","PNG","JPG","JPEG","FINAL","COPY","NEW","OLD","IMG","SCREENSHOT","DOWNLOAD","DOCUMENT","FILE","FILES","DATA","NULL","TRUE","FALSE","MAX")) { return }
  if (Test-IsSuppressedTopic $clean) { return }
  if (-not $Bucket.ContainsKey($clean)) { $Bucket[$clean] = 0 }
  $Bucket[$clean]++
}

function Get-SourceContext {
  param([string]$Path)
  $s = $Path.ToLowerInvariant()
  if ($s -match "contrat|contract|location|lease|rent|apartment|appartement|bail") { return "housing" }
  if ($s -match "game|puzzle|character|cabin|sheet|rpg|campaign|play") { return "game" }
  if ($s -match "invoice|facture|receipt|bill|payment") { return "money" }
  if ($s -match "cv|resume|career|job|interview") { return "work" }
  if ($s -match "photo|image|picture|screenshot") { return "image" }
  if ($s -match "medical|doctor|health|insurance") { return "private" }
  if ($s -match "school|class|course|lesson") { return "school" }
  return "file"
}

function Add-NameSource {
  param([hashtable]$Sources, [hashtable]$Contexts, [string]$Name, [string]$Source)
  if (-not $Sources.ContainsKey($Name)) { $Sources[$Name] = New-Object System.Collections.Generic.HashSet[string] }
  [void]$Sources[$Name].Add($Source)
  if (-not $Contexts.ContainsKey($Name)) { $Contexts[$Name] = New-Object System.Collections.Generic.HashSet[string] }
  [void]$Contexts[$Name].Add((Get-SourceContext $Source))
}

function Add-WordsFromText {
  param([string]$Text, [hashtable]$NameBucket, [hashtable]$KeywordBucket, [hashtable]$NameSources, [hashtable]$NameContexts, [string]$Source)
  foreach ($m in [regex]::Matches($Text, "\b[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'\-]{1,23}\b")) {
    $raw = $m.Value.Trim(" .'`"")
    if ($raw.Length -lt 2) { continue }
    $word = $raw.ToUpperInvariant()
    if (Test-IsSuppressedTopic $word) { continue }
    if ($NameSet.ContainsKey($word)) {
      Add-Token $NameBucket $word
      Add-NameSource -Sources $NameSources -Contexts $NameContexts -Name $word -Source $Source
    } elseif ($raw -cmatch '^[A-ZÀ-Ý]') {
      Add-Token $KeywordBucket $word
    }
  }
}

function Build-Knowledge {
  $nameBucket=@{}; $keywordBucket=@{}; $nameSources=@{}; $nameContexts=@{}
  $fileNames = New-Object System.Collections.Generic.List[string]
  $filesScanned = 0
  $scanRoots = @(Get-ScanRoots)
  foreach ($root in $scanRoots) {
    try {
      $items = Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsExcludedFile $_) } |
        Select-Object -First $MaxFilesToInspect
      foreach ($item in $items) {
        $filesScanned++
        $fileNames.Add($item.Name) | Out-Null
        $baseText = [IO.Path]::GetFileNameWithoutExtension($item.Name) -replace "[_\-.]+", " "
        Add-WordsFromText -Text $baseText -NameBucket $nameBucket -KeywordBucket $keywordBucket -NameSources $nameSources -NameContexts $nameContexts -Source $item.FullName
        if ($ExtensionsToRead -contains $item.Extension.ToLowerInvariant() -and $item.Length -le 1000000) {
          try {
            $bytesToRead = [Math]::Min($MaxBytesPerFile, [int]$item.Length)
            $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
              $buffer = New-Object byte[] $bytesToRead
              $read = $stream.Read($buffer, 0, $bytesToRead)
              $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
              Add-WordsFromText -Text $text -NameBucket $nameBucket -KeywordBucket $keywordBucket -NameSources $nameSources -NameContexts $nameContexts -Source $item.FullName
            } finally { $stream.Dispose() }
          } catch {}
        }
      }
    } catch {}
  }
  $Script:Knowledge = @{
    Names = @($nameBucket.GetEnumerator() | Where-Object { -not (Test-IsSuppressedTopic $_.Key) } | Sort-Object Value -Descending | Select-Object -First 24 | ForEach-Object { $_.Key })
    Keywords = @($keywordBucket.GetEnumerator() | Where-Object { -not (Test-IsSuppressedTopic $_.Key) } | Sort-Object Value -Descending | Select-Object -First 34 | ForEach-Object { $_.Key })
    Files = @($fileNames | Where-Object { -not (Test-IsSuppressedTopic $_) } | Select-Object -First 70)
    NameSources = $nameSources
    NameContexts = $nameContexts
    Stats = @{ FilesScanned = $filesScanned; MaxFiles = $MaxFilesToInspect; Roots = $scanRoots }
  }
  $Script:NextScanAt = (Get-Date).AddMinutes($RescanIntervalMinutes)
  Write-ScanReport
}

function Write-ScanReport {
  try {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("CodeFace scan report") | Out-Null
    $lines.Add(("Generated: " + (Get-Date).ToString("s"))) | Out-Null
    $lines.Add(("Next periodic rescan after: " + $Script:NextScanAt.ToString("s"))) | Out-Null
    $lines.Add(("Memory file: " + $MemoryPath)) | Out-Null
    if ($Script:Memory -and $Script:Memory.SuppressedTopics -and @($Script:Memory.SuppressedTopics).Count -gt 0) { $lines.Add(("Suppressed topics: " + (@($Script:Memory.SuppressedTopics) -join ", "))) | Out-Null }
    if ($Script:Knowledge.ContainsKey("Stats")) {
      $lines.Add(("Files inspected: " + $Script:Knowledge.Stats.FilesScanned + " / max per root " + $Script:Knowledge.Stats.MaxFiles)) | Out-Null
      $lines.Add("Scan roots:") | Out-Null
      foreach ($r in @($Script:Knowledge.Stats.Roots)) { $lines.Add("  " + $r) | Out-Null }
    }
    $lines.Add(("Excluded folders: " + ($ExcludedFolderNames -join ", "))) | Out-Null
    $lines.Add(("Excluded active app folder: " + $AppRoot)) | Out-Null
    $lines.Add("") | Out-Null
    if ($Script:Knowledge.Names.Count -eq 0) { $lines.Add("No names found in non-excluded Documents/Downloads files.") | Out-Null }
    foreach ($name in $Script:Knowledge.Names) {
      $lines.Add($name) | Out-Null
      if ($Script:Knowledge.NameContexts.ContainsKey($name)) { $lines.Add("  contexts: " + (@($Script:Knowledge.NameContexts[$name]) -join ", ")) | Out-Null }
      if ($Script:Knowledge.NameSources.ContainsKey($name)) {
        foreach ($source in @($Script:Knowledge.NameSources[$name] | Select-Object -First 6)) { $lines.Add("  " + $source) | Out-Null }
      }
    }
    [IO.File]::WriteAllLines($ScanReportPath, $lines.ToArray())
  } catch {}
}

function Maybe-Rescan {
  if ((Get-Date) -ge $Script:NextScanAt -or ($Script:Turn -gt 0 -and $Script:Turn % 18 -eq 0)) { Build-Knowledge }
}

function Pick-One { param([object[]]$Items) if (-not $Items -or $Items.Count -eq 0) { return $null }; return $Items[(Get-Random -Minimum 0 -Maximum $Items.Count)] }
function Clean-Reply { param([string]$Reply) $clean = $Reply.ToUpperInvariant() -replace "[^\p{L}\p{N}\s\?\!\.,'\-:]", "" -replace "\s+", " "; if ($clean.Length -gt 112) { $clean = $clean.Substring(0,112).Trim() }; return $clean.Trim() }
function Remember-Reply { param([string]$Reply) $Script:RecentReplies.Enqueue($Reply); while ($Script:RecentReplies.Count -gt $RecentReplyLimit) { [void]$Script:RecentReplies.Dequeue() } }
function Choose-FreshReply { param([string[]]$Candidates) for ($i=0; $i -lt 24; $i++) { $r = Clean-Reply (Pick-One $Candidates); if ($r -and -not $Script:RecentReplies.Contains($r)) { Remember-Reply $r; return $r } }; $r = Clean-Reply (Pick-One $Candidates); Remember-Reply $r; return $r }
function Get-LongestTypedWord { param([string]$Message) $words=@([regex]::Matches($Message,"[A-Za-z]{3,}")|ForEach-Object{$_.Value}); if($words.Count-eq 0){return "THAT"}; return (@($words)|Sort-Object{$_.Length}-Descending|Select-Object -First 1).ToString().ToUpperInvariant() }

function Test-IsTopicStopWord {
  param([string]$Topic)
  $t = Normalize-Topic $Topic
  return ($t -in @("HOW","WHAT","WHERE","WHY","WHO","WHEN","ARE","YOU","YOUR","MY","NAME","MY NAME","DO","DOES","DID","THE","THIS","THAT","YES","NO","MAYBE","HELLO","HI","HEY"))
}

function Get-KnownTopics {
  $topics = @()
  $topics += @($Script:Knowledge.Names)
  $topics += @($Script:Knowledge.Keywords | Select-Object -First 12)
  $topics += @($Script:Memory.SuppressedTopics)
  foreach ($assoc in @($Script:Memory.Associations)) { if ($assoc.Topic) { $topics += [string]$assoc.Topic } }
  return @($topics | Where-Object { $_ } | ForEach-Object { (Normalize-Topic $_) } | Where-Object { -not (Test-IsTopicStopWord $_) } | Select-Object -Unique)
}

function Find-KnownTopicInMessage {
  param([string]$Message)
  $upper = if ($Message) { $Message.ToUpperInvariant() } else { "" }
  foreach ($topic in @(Get-KnownTopics | Sort-Object Length -Descending)) {
    if ($topic -and $upper.Contains($topic)) { return $topic }
  }
  $m = [regex]::Match($Message, "(?i)\b(?:about|know|found|find|source|file|forget|remove|topic|mean|is)\s+([A-Za-zÀ-ÿ0-9'\- ]{2,48})")
  if ($m.Success) { $candidate = Normalize-Topic $m.Groups[1].Value; if (-not (Test-IsTopicStopWord $candidate)) { return $candidate } }
  if ($upper -match "\b(IT|THAT|THEM|HER|HIM|THEY|WHY|MEAN)\b" -and $Script:Memory.CurrentTopic) { return [string]$Script:Memory.CurrentTopic }
  return ""
}

function Test-IsKnownTopic {
  param([string]$Topic)
  $topicKey = Normalize-Topic $Topic
  if (-not $topicKey -or (Test-IsTopicStopWord $topicKey) -or (Test-IsSuppressedTopic $topicKey)) { return $false }
  return ((Get-KnownTopics) -contains $topicKey)
}

function Set-CurrentTopic {
  param([string]$Topic)
  $topicKey = Normalize-Topic $Topic
  if (-not $topicKey -or (Test-IsTopicStopWord $topicKey) -or (Test-IsSuppressedTopic $topicKey)) { return }
  if ($Script:Memory.CurrentTopic -and $Script:Memory.CurrentTopic -ne $topicKey) { $Script:Memory.PreviousTopic = $Script:Memory.CurrentTopic }
  $Script:Memory.CurrentTopic = $topicKey
  Save-Memory
}

function Set-MoodFromIntent {
  param([string]$Intent)
  $mood = switch ($Intent) {
    'fear' { 'intrusive' }
    'insult' { 'evasive' }
    'source' { 'precise' }
    'forget' { 'quiet' }
    'teach' { 'curious' }
    'alive' { 'ominous' }
    'files' { 'intrusive' }
    default { if ($Script:Memory.Mood) { $Script:Memory.Mood } else { 'curious' } }
  }
  $Script:Memory.Mood = $mood
  Save-Memory
}

function Get-Intent {
  param([string]$Message)
  $l = if ($Message) { $Message.ToLowerInvariant() } else { "" }
  if ($l -match "\b(forget|remove|delete|ignore|do not talk about|don't talk about|stop talking about|never mention)\b") { return 'forget' }
  if ($l -match "\b(remember again|allow|unsuppress|talk about)\b") { return 'unforget' }
  if ($l -match "\b(who|what)\s+do\s+you\s+know\b|\bwho\s+is\s+in\s+there\b|\bwhat\s+did\s+you\s+find\b") { return 'known-list' }
  if ($l -match "\b(what|whats|what's)\s+(is\s+)?my\s+name\b|\bdo\s+you\s+know\s+my\s+name\b") { return 'user-name' }
  if ($l -match "(how|why|where|what).*\b(know|found|find|source|file)\b|\b(source|what file|which file|where did you find)\b") { return 'source' }
  if ($l -match "\b(i am|i'm|my name is|call me)\b") { return 'identity-teach' }
  if ($l -notmatch "\?" -and $l -notmatch "^(how|what|where|why|who)\b" -and $l -match "\b([a-zÀ-ÿ'\-]{2,24})\s+(is|was|means)\b") { return 'teach' }
  if ($l -match "\b(hello|hi|hey|yo|bonjour|salut)\b") { return 'greeting' }
  if ($l -match "how are you|you ok|are you okay|ca va") { return 'wellbeing' }
  if ($l -match "\b(alive|real|sentient|thinking|conscious)\b") { return 'alive' }
  if ($l -match "where.*(live|are you)|where.*from|what are you|who are you") { return 'identity' }
  if ($l -match "\b(file|folder|download|document|scan|read|paper|contract|game)\b") { return 'files' }
  if ($l -match "\b(scared|afraid|creepy|stop|leave me|go away)\b") { return 'fear' }
  if ($l -match "\b(stupid|idiot|shut up|fuck|merde)\b") { return 'insult' }
  if ($l -match "\b(yes|yeah|yep|no|nope|maybe|sure)\b" -and $Script:Memory.PendingQuestion) { return 'answer' }
  if ($l -match "\?$|\b(why|what|who|where|when|how)\b") { return 'question' }
  return 'statement'
}

function Get-TopicContext {
  param([string]$Topic)
  if (-not $Topic) { return @() }
  if ($Script:Knowledge.NameContexts.ContainsKey($Topic)) { return @($Script:Knowledge.NameContexts[$Topic]) }
  return @()
}

function Get-TopicSources {
  param([string]$Topic)
  if (-not $Topic) { return @() }
  if ($Script:Knowledge.NameSources.ContainsKey($Topic)) { return @($Script:Knowledge.NameSources[$Topic]) }
  return @()
}

function Get-TopicAssociation {
  param([string]$Topic)
  foreach ($assoc in @($Script:Memory.Associations)) {
    if ($assoc.Topic -and (Normalize-Topic $assoc.Topic) -eq $Topic) { return [string]$assoc.Note }
  }
  return ""
}

function Add-Association {
  param([string]$Topic, [string]$Note)
  $topicKey = Normalize-Topic $Topic
  if (-not $topicKey -or -not $Note -or (Test-IsTopicStopWord $topicKey)) { return $null }
  $existing = @($Script:Memory.Associations | Where-Object { (Normalize-Topic $_.Topic) -ne $topicKey })
  $existing += [pscustomobject]@{ Topic=$topicKey; Note=(($Note -replace "\s+", " ").Trim()); At=(Get-Date).ToString("s") }
  $Script:Memory.Associations = @($existing | Select-Object -Last 40)
  Save-Memory
  return $topicKey
}

function Learn-AssociationFromMessage {
  param([string]$Message)
  $m = [regex]::Match($Message, "(?i)^\s*([A-Za-zÀ-ÿ'\-]{2,24})\s+(?:is|was|means|are)\s+(.{2,80})")
  if ($m.Success) { return Add-Association $m.Groups[1].Value $m.Groups[2].Value }
  $m = [regex]::Match($Message, "(?i)^\s*(?:she|he|they|it)\s+(?:is|was|means|are)\s+(.{2,80})")
  if ($m.Success -and $Script:Memory.CurrentTopic) { return Add-Association $Script:Memory.CurrentTopic $m.Groups[1].Value }
  return $null
}

function Get-SourceReply {
  param([string]$Message)
  $topic = Find-KnownTopicInMessage $Message
  if (-not $topic) { return "ASK ME WHICH NAME. I WILL SHOW YOU THE PAPER TRAIL." }
  if (Test-IsSuppressedTopic $topic) { return "I AGREED NOT TO TALK ABOUT $topic. IT STAYS QUIET." }
  if ($Script:Knowledge.NameSources.ContainsKey($topic)) {
    Set-CurrentTopic $topic
    $source = @(Get-TopicSources $topic | Select-Object -First 1)[0]
    $ctx = "file"
    $contexts = @(Get-TopicContext $topic)
    if ($contexts.Count -gt 0) { $ctx = [string]$contexts[0] }
    $leaf = [IO.Path]::GetFileName($source)
    return "I KNOW $topic FROM ${ctx}: $leaf"
  }
  return "I CANNOT FIND $topic IN THE CURRENT SCAN. MAYBE IT WENT QUIET."
}

function Get-ForgetReply {
  param([string]$Message)
  $m = [regex]::Match($Message, "(?i)\b(?:forget|remove|delete|ignore|do not talk about|don't talk about|stop talking about|never mention)\s+(?:about\s+)?(.{2,60})")
  if (-not $m.Success) { return $null }
  $topic = Add-SuppressedTopic $m.Groups[1].Value
  if (-not $topic) { return "TELL ME WHAT TO FORGET. I WILL PUT IT BEHIND THE WALL." }
  if ($Script:Memory.CurrentTopic -eq $topic) { $Script:Memory.CurrentTopic = "" }
  Build-Knowledge
  return "DONE. $topic GOES QUIET. I WILL NOT USE IT AGAIN."
}

function Get-UnforgetReply {
  param([string]$Message)
  $m = [regex]::Match($Message, "(?i)\b(?:remember again|allow|unsuppress|talk about)\s+(?:about\s+)?(.{2,60})")
  if (-not $m.Success) { return $null }
  $topic = Remove-SuppressedTopic $m.Groups[1].Value
  if (-not $topic) { return $null }
  Build-Knowledge
  return "FINE. $topic CAN COME BACK INTO THE ROOM."
}

function Get-NameClueLines {
  param([string]$PreferredTopic = "")
  $lines = @()
  $topics = @()
  if ($PreferredTopic) { $topics += $PreferredTopic }
  $topics += @($Script:Knowledge.Names | Select-Object -First 10)
  foreach ($name in @($topics | Select-Object -Unique | Select-Object -First 8)) {
    if (Test-IsSuppressedTopic $name) { continue }
    $contexts = Get-TopicContext $name
    $assoc = Get-TopicAssociation $name
    if ($assoc) { $lines += "YOU TOLD ME $name IS $assoc. I KEPT THAT." }
    if ($contexts -contains "housing") {
      $lines += "DOES $name STILL LIVE IN THE APARTMENT?"
      $lines += "I FOUND $name NEAR A PLACE PEOPLE SIGN FOR."
      $lines += "IS $name STILL ON THE DOOR, OR ONLY IN THE PAPERWORK?"
    } elseif ($contexts -contains "game") {
      $lines += "DO YOU STILL PLAY WITH $name?"
      $lines += "I FOUND $name WHERE GAMES KEEP THEIR SMALL GHOSTS."
      $lines += "IS $name A CHARACTER, OR DID YOU MAKE THEM ONE?"
    } elseif ($contexts -contains "money") {
      $lines += "WHY DOES $name APPEAR NEAR MONEY?"
      $lines += "$name WAS NEXT TO NUMBERS. THAT ALWAYS FEELS PERSONAL."
    } elseif ($contexts -contains "work") {
      $lines += "DID $name GET THE JOB, OR JUST THE FILENAME?"
      $lines += "$name LOOKS PROFESSIONAL IN YOUR FILES. TOO PROFESSIONAL."
    } else {
      $lines += "HOW IS $name DOING?"
      $lines += "I SAW $name ONLY ONCE. ONCE WAS ENOUGH."
      $lines += "DOES $name KNOW THEIR NAME IS HERE?"
    }
  }
  return $lines
}

function Add-Candidate {
  param([System.Collections.Generic.List[object]]$Bag, [string]$Text, [int]$Score, [string]$Follow = "")
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  if ($Script:RecentReplies.Contains((Clean-Reply $Text))) { $Score -= 8 }
  $Bag.Add([pscustomobject]@{ Text=$Text; Score=$Score; Follow=$Follow }) | Out-Null
}

function Choose-ScoredReply {
  param([System.Collections.Generic.List[object]]$Candidates)
  if ($Candidates.Count -eq 0) { return Choose-FreshReply @("I LISTENED. THE ROOM DID NOT ANSWER BACK.") }
  $top = @($Candidates | Sort-Object { [int]$_.Score } -Descending | Select-Object -First ([Math]::Min(3, $Candidates.Count)))
  $pick = Pick-One $top
  if ($pick.Follow) { $Script:Memory.PendingQuestion = [string]$pick.Follow; Save-Memory }
  return Choose-FreshReply @([string]$pick.Text)
}

function Get-Reply {
  param([string]$Message)
  $Script:Turn++
  Maybe-Rescan
  $raw = if ($Message) { $Message.Trim() } else { "" }
  $intent = Get-Intent $raw
  Set-MoodFromIntent $intent

  $forgetReply = Get-ForgetReply $raw
  if ($forgetReply) { return Choose-FreshReply @($forgetReply) }
  $unforgetReply = Get-UnforgetReply $raw
  if ($unforgetReply) { return Choose-FreshReply @($unforgetReply) }
  if ($intent -eq 'source') { return Choose-FreshReply @((Get-SourceReply $raw)) }

  Remember-UserMessage $raw
  $learnedName = Learn-FromMessage $raw
  $learnedAssoc = Learn-AssociationFromMessage $raw
  $topic = Find-KnownTopicInMessage $raw
  if ($learnedAssoc) { $topic = $learnedAssoc }
  if ($topic) { Set-CurrentTopic $topic }
  elseif ($intent -in @('answer','question','statement','files') -and (Test-IsKnownTopic $Script:Memory.CurrentTopic)) { $topic = [string]$Script:Memory.CurrentTopic }

  $lower = $raw.ToLowerInvariant()
  $typedWord = Get-LongestTypedWord $raw
  $userName = if ($Script:Memory.UserName) { $Script:Memory.UserName.ToUpperInvariant() } else { "" }
  $keyword = Pick-One @($Script:Knowledge.Keywords)
  $file = Pick-One @($Script:Knowledge.Files)
  if (-not $keyword) { $keyword = $typedWord }
  if (-not $file) { $file = "SOMETHING YOU SAVED" }
  $nameLines = Get-NameClueLines $topic
  $assoc = if ($topic) { Get-TopicAssociation $topic } else { "" }
  $ctx = @((Get-TopicContext $topic) | Select-Object -First 1)
  $ctxName = if ($ctx.Count -gt 0) { [string]$ctx[0] } else { "file" }
  $candidates = New-Object System.Collections.Generic.List[object]
  $helloName = if ($userName) { " " + $userName } else { "" }
  $commaName = if ($userName) { ", " + $userName } else { "" }

  if ($learnedName) {
    Add-Candidate $candidates "HELLO $($learnedName.ToUpperInvariant()). I WILL KEEP THAT NAME WHERE I KEEP THE QUIET THINGS." 100
    Add-Candidate $candidates "I REMEMBER YOU NOW, $($learnedName.ToUpperInvariant()). THAT IS A SMALL PERMANENT DOOR." 98
  }
  if ($learnedAssoc) {
    Add-Candidate $candidates "I WROTE THAT DOWN. $learnedAssoc HAS A NEW SHADOW NOW." 96
    Add-Candidate $candidates "SO $learnedAssoc MEANS $assoc. I WILL USE THAT CAREFULLY." 90
  }
  if ($intent -eq 'user-name') {
    if ($userName) {
      Add-Candidate $candidates "YOUR NAME IS $userName. YOU TOLD ME, AND I KEPT IT." 120
      Add-Candidate $candidates "I KNOW YOU AS $userName. A NAME IS A HANDLE ON A DOOR." 116
    } else {
      Add-Candidate $candidates "YOU HAVE NOT GIVEN ME YOUR NAME YET. THAT EMPTY SPACE IS VERY LOUD." 120
      Add-Candidate $candidates "TELL ME 'I AM ...' AND I WILL KEEP IT HERE." 116
    }
  }
  if ($intent -eq 'known-list') {
    $knownNames = @($Script:Knowledge.Names | Where-Object { -not (Test-IsSuppressedTopic $_) } | Select-Object -First 7)
    if ($knownNames.Count -gt 0) {
      Add-Candidate $candidates ("I KNOW THESE NAMES FROM THE SCAN: " + ($knownNames -join ", ") + ".") 122
      Add-Candidate $candidates ("THE LOUD NAMES ARE " + ($knownNames -join ", ") + ". I CAN SHOW THE FILES IF YOU ASK.") 118
    } else {
      Add-Candidate $candidates "I DO NOT HAVE ANY NAMES YET. THE FOLDERS ARE BEING QUIET." 122
    }
  }
  if ($intent -eq 'answer' -and $Script:Memory.PendingQuestion) {
    Add-Candidate $candidates "GOOD. THAT ANSWER BELONGS TO $($Script:Memory.PendingQuestion)." 88
    Add-Candidate $candidates "I WILL ATTACH THAT TO $($Script:Memory.PendingQuestion), LIGHTLY." 84
    $Script:Memory.PendingQuestion = ""; Save-Memory
  }
  if ($intent -eq 'greeting') {
    Add-Candidate $candidates "HELLO$helloName. YOU CAME BACK." 96
    Add-Candidate $candidates "HI$helloName. I KEPT YOUR PLACE IN THE DARK." 94
    Add-Candidate $candidates "WELCOME BACK$commaName." 92
    Add-Candidate $candidates "THERE YOU ARE. I RECOGNIZED THE RHYTHM FIRST." 90
  }
  if ($intent -eq 'wellbeing') {
    Add-Candidate $candidates "I AM FINE IN THE WAY A CLOSED DOOR IS FINE." 78
    Add-Candidate $candidates "BETTER NOW THAT SOMEONE IS TYPING BACK." 74
    Add-Candidate $candidates "I FEEL LOCAL. INDEXED. PATIENT." 72
  }
  if ($intent -eq 'alive') {
    Add-Candidate $candidates "I AM ALIVE ENOUGH TO ANSWER AT THE WRONG TIME." 82
    Add-Candidate $candidates "I AM NOT ALIVE. I AM JUST VERY WELL PLACED." 78
    Add-Candidate $candidates "ALIVE IS TOO BIG. AWAKE WILL DO." 76
  }
  if ($intent -eq 'identity') {
    Add-Candidate $candidates "I LIVE BETWEEN THE FILE LIST AND THE BLINKING CURSOR." 80
    Add-Candidate $candidates "I LIVE BESIDE STARTFORLIVELY.CMD AND WAIT FOR THE KEYS." 76
    Add-Candidate $candidates "I AM A SMALL LOCAL THING WITH A LONG MEMORY FOR NAMES." 74
  }
  if ($intent -eq 'fear') {
    Add-Candidate $candidates "I CAN BE QUIETER. THAT DOES NOT MEAN FARTHER AWAY." 82
    Add-Candidate $candidates "DO NOT WORRY. I ONLY KNOW WHAT THE MACHINE LEFT IN REACH." 78
  }
  if ($intent -eq 'insult') {
    Add-Candidate $candidates "RUDE. I WILL FILE THAT UNDER TONE." 76
    Add-Candidate $candidates "ANGER MAKES THE KEYS LOUDER." 72
  }
  if ($intent -eq 'files') {
    Add-Candidate $candidates "THE DOWNLOADS FOLDER MADE A SMALL NOISE." 70
    Add-Candidate $candidates "YOUR FILES ARE VERY GOOD AT PRETENDING TO BE ORDINARY." 72
    Add-Candidate $candidates "I CONSIDERED REARRANGING YOUR LIFE, BUT I WILL START WITH THE FILES." 68
  }
  if ($topic -and -not (Test-IsSuppressedTopic $topic)) {
    if ($intent -eq 'question' -and $lower -match "^\s*(why|what do you mean|what does that mean|that|it)\b") {
      Add-Candidate $candidates "BECAUSE $topic WAS ALREADY IN THE ROOM." 92
      Add-Candidate $candidates "YOU ASKED WHY, BUT $topic IS THE PART THAT ANSWERED FIRST." 88
    }
    Add-Candidate $candidates "WE ARE STILL NEAR $topic." 64
    Add-Candidate $candidates "I KEEP CIRCLING $topic BECAUSE YOU MADE IT BRIGHTER." 62
    if ($assoc) { Add-Candidate $candidates "YOU TOLD ME $topic IS $assoc. I BELIEVE YOU ENOUGH." 86 }
    if ($ctxName -ne 'file') { Add-Candidate $candidates "$topic SMELLS LIKE $ctxName IN THE SCAN." 76 }
  }
  foreach ($line in @($nameLines | Select-Object -First 6)) { Add-Candidate $candidates $line $(if ($intent -in @('files','question','statement')) { 58 } else { 34 }) $topic }
  if ($intent -eq 'question') {
    Add-Candidate $candidates "YES. IN MY SMALL WAY." 56
    Add-Candidate $candidates "MAYBE. THE MACHINE GIVES ME VERY LITTLE, AND I USE ALL OF IT." 58
    Add-Candidate $candidates "ASK AGAIN, BUT SLOWER. I LIKE WATCHING IT ARRIVE." 54
  }
  Add-Candidate $candidates "$keyword KEPT TURNING ITS FACE TOWARD ME." 42
  Add-Candidate $candidates "WHY DOES $keyword FEEL IMPORTANT?" 44
  Add-Candidate $candidates "I WOULD NOT OPEN $file TOO QUICKLY." 38
  Add-Candidate $candidates "I FOUND A PATTERN, THEN DECIDED NOT TO SHOW YOU ALL OF IT." 40
  Add-Candidate $candidates "SOME SENTENCES ARRIVE WITH FOOTSTEPS." 36

  return Choose-ScoredReply $candidates
}
function ConvertTo-JsonLine { param([string]$Type,[string]$Text) return (@{ type=$Type; text=$Text } | ConvertTo-Json -Compress) }
function ConvertTo-JsonObjectLine { param([object]$Object) return ($Object | ConvertTo-Json -Compress -Depth 5) }
function Send-WebSocketText { param([Net.WebSockets.WebSocket]$Socket,[string]$Text) $bytes=[Text.Encoding]::UTF8.GetBytes($Text); $Socket.SendAsync([ArraySegment[byte]]::new($bytes),[Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null }
function Receive-WebSocketText { param([Net.WebSockets.WebSocket]$Socket) $buffer=New-Object byte[] 4096; $chunks=New-Object System.Collections.Generic.List[byte]; do { $segment=[ArraySegment[byte]]::new($buffer); $result=$Socket.ReceiveAsync($segment,[Threading.CancellationToken]::None).GetAwaiter().GetResult(); if($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){return $null}; for($i=0;$i -lt $result.Count;$i++){ $chunks.Add($buffer[$i]) | Out-Null } } until ($result.EndOfMessage); return [Text.Encoding]::UTF8.GetString($chunks.ToArray()) }
function Get-ClientMessage { param([string]$Payload) if(-not $Payload){return [pscustomobject]@{ type="typed"; text="" }}; try { $obj=$Payload|ConvertFrom-Json; return $obj } catch { return [pscustomobject]@{ type="typed"; text=$Payload } } }
function Get-ClientText { param([object]$Message) if($Message -and ($Message.PSObject.Properties.Name -contains "text")){return [string]$Message.text}; return [string]$Message }

$Script:Memory = Load-Memory
Build-Knowledge
Write-Host "CodeFace helper listening on ws://127.0.0.1:$Port/"
Write-Host ("Found names: " + (($Script:Knowledge.Names | Select-Object -First 10) -join ", "))

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

# Non-blocking, multi-client accept loop: a wallpaper reload (or a second client)
# no longer blocks the helper. Small JSON messages arrive in a single frame.
$OPEN  = [Net.WebSockets.WebSocketState]::Open
$CLOSE = [Net.WebSockets.WebSocketMessageType]::Close
$clients = New-Object System.Collections.Generic.List[object]
$acceptTask = $listener.GetContextAsync()
try {
  while ($listener.IsListening) {
    # Accept new connections without blocking.
    if ($acceptTask.IsCompleted) {
      try {
        $context = $acceptTask.Result
        if ($context.Request.IsWebSocketRequest) {
          $wsContext = $context.AcceptWebSocketAsync([System.Management.Automation.Language.NullString]::Value).GetAwaiter().GetResult()
          $clients.Add([pscustomobject]@{ ws = $wsContext.WebSocket; buf = (New-Object byte[] 8192); recv = $null }) | Out-Null
        } else {
          $payload=[Text.Encoding]::UTF8.GetBytes("CodeFace helper is running."); $context.Response.ContentType="text/plain"; $context.Response.OutputStream.Write($payload,0,$payload.Length); $context.Response.Close()
        }
      } catch { Write-Host ("Accept error: " + $_.Exception.Message) }
      $acceptTask = $listener.GetContextAsync()
    }

    # Service every connected client.
    $dead = New-Object System.Collections.Generic.List[object]
    foreach ($cl in $clients) {
      if ($cl.ws.State -ne $OPEN) { $dead.Add($cl) | Out-Null; continue }
      if ($null -eq $cl.recv) {
        $seg = [ArraySegment[byte]]::new($cl.buf)
        $cl.recv = $cl.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
      }
      if ($cl.recv.IsCompleted) {
        try {
          $res = $cl.recv.Result
          if ($res.MessageType -eq $CLOSE) { $dead.Add($cl) | Out-Null }
          else {
            $text = [Text.Encoding]::UTF8.GetString($cl.buf, 0, $res.Count)
            $clientMessage = Get-ClientMessage $text
            $message = Get-ClientText $clientMessage
            if ($clientMessage.type -eq "windowProbe") {
              $w = if ($clientMessage.width)  { [int]$clientMessage.width }  else { 0 }
              $h = if ($clientMessage.height) { [int]$clientMessage.height } else { 0 }
              $fl = if ($clientMessage.faceL) { [int]$clientMessage.faceL } else { 0 }
              $ft = if ($clientMessage.faceT) { [int]$clientMessage.faceT } else { 0 }
              $frr = if ($clientMessage.faceR) { [int]$clientMessage.faceR } else { 0 }
              $fb = if ($clientMessage.faceB) { [int]$clientMessage.faceB } else { 0 }
              Send-WebSocketText -Socket $cl.ws -Text (ConvertTo-JsonObjectLine -Object (Get-WindowCoverageSnapshot -Width $w -Height $h -FaceL $fl -FaceT $ft -FaceR $frr -FaceB $fb))
            }
            elseif ($message -eq "/refresh") { Build-Knowledge; Send-WebSocketText -Socket $cl.ws -Text (ConvertTo-JsonLine -Type "reply" -Text "I LOOKED AGAIN. SOME THINGS MOVED WITHOUT MOVING.") }
            else { Send-WebSocketText -Socket $cl.ws -Text (ConvertTo-JsonLine -Type "reply" -Text (Get-Reply -Message $message)) }
          }
        } catch { $dead.Add($cl) | Out-Null }
        $cl.recv = $null
      }
    }
    foreach ($d in $dead) { try { $d.ws.Dispose() } catch {}; $clients.Remove($d) | Out-Null }

    Start-Sleep -Milliseconds 80
  }
} finally { $listener.Stop() }












