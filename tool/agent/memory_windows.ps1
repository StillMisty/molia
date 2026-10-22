param(
  [string]$Exe = 'C:\Users\Still\molia-perf\build\windows\x64\runner\Release\molia.exe',
  [string]$OutDir = 'C:\Users\Still\AppData\Local\Temp\molia-perf',
  [int]$IdleSeconds = 5,
  [int]$PlaySeconds = 8
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MoliaMemWin32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Get-PrivateWorkingSet([int]$ProcId) {
  try {
    $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
      -Filter "IDProcess = $ProcId" -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $perf -and $null -ne $perf.WorkingSetPrivate) {
      return [double]$perf.WorkingSetPrivate
    }
  } catch { }
  return $null
}

$rows = New-Object System.Collections.Generic.List[object]
function Sample([string]$State) {
  $p = Get-Process molia -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $p) {
    $rows.Add([pscustomobject]@{ state = $State; ws_mb = $null; private_mb = $null; commit_mb = $null })
    return
  }
  $p.Refresh()
  $private = Get-PrivateWorkingSet $p.Id
  $row = [pscustomobject]@{
    state = $State
    ws_mb = [math]::Round($p.WorkingSet64 / 1MB, 1)
    private_mb = if ($null -ne $private) { [math]::Round($private / 1MB, 1) } else { $null }
    commit_mb = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
    handle = $p.MainWindowHandle
  }
  $rows.Add($row)
  Write-Host ("[mem] {0,-16} memory={1}MB commit={2}MB" -f $State, $row.private_mb, $row.commit_mb)
}

Get-Process molia -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

# 默认落到收藏页、滚动位置清零，保证「浏览」场景从同一屏开始。
$prefsPath = Join-Path $env:APPDATA 'top.stillmisty\molia\shared_preferences.json'
if (Test-Path $prefsPath) {
  $prefs = Get-Content -Raw -Encoding UTF8 $prefsPath | ConvertFrom-Json
  $prefs.'flutter.favorites_scroll_offsets' = '{"favorites":0.0,"history":0.0,"downloads":0.0}'
  $prefs.'flutter.shell_home_destination' = 'favorites'
  $json = $prefs | ConvertTo-Json -Depth 20 -Compress
  [System.IO.File]::WriteAllText(
    $prefsPath, $json, (New-Object System.Text.UTF8Encoding($false))
  )
}

$stdout = Join-Path $OutDir 'memory-release.log'
$stderr = Join-Path $OutDir 'memory-release.err.log'
Remove-Item -Force $stdout, $stderr -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $Exe `
  -WorkingDirectory (Split-Path $Exe) `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError $stderr `
  -PassThru

$deadline = (Get-Date).AddSeconds(20)
$handle = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
  $proc = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
  if ($null -eq $proc) { break }
  $proc.Refresh()
  if ($proc.MainWindowHandle -ne 0) { $handle = $proc.MainWindowHandle; break }
  Start-Sleep -Milliseconds 50
}
if ($handle -eq [IntPtr]::Zero) { throw '窗口未出现' }

Start-Sleep -Seconds $IdleSeconds
Sample 'idle'

[MoliaMemWin32]::SetForegroundWindow($handle) | Out-Null
$wshell = New-Object -ComObject WScript.Shell
$wshell.AppActivate($p.Id) | Out-Null
Start-Sleep -Milliseconds 500
[MoliaMemWin32]::SetForegroundWindow($handle) | Out-Null
$rect = New-Object MoliaMemWin32+RECT
[MoliaMemWin32]::GetWindowRect($handle, [ref]$rect) | Out-Null
$cx = [int](($rect.Left + $rect.Right) / 2)
$cy = [int](($rect.Top + $rect.Bottom) / 2)
[MoliaMemWin32]::SetCursorPos($cx, $cy) | Out-Null
for ($i = 0; $i -lt 80; $i++) {
  [MoliaMemWin32]::mouse_event(0x0800, 0, 0, -120, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 25
}
Start-Sleep -Seconds 2
Sample 'browse'

# 媒体键：播放 / 暂停（VK_MEDIA_PLAY_PAUSE）。
[MoliaMemWin32]::keybd_event(0xB3, 0, 0, [UIntPtr]::Zero)
[MoliaMemWin32]::keybd_event(0xB3, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Seconds $PlaySeconds
Sample 'playing'

$proc = Get-Process molia -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $proc) { $proc.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 3
Sample 'tray'

# 单实例唤起：再次启动 exe 会把已有实例的窗口显示出来。
Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) | Out-Null
Start-Sleep -Seconds 3
Sample 'restored'

Get-Process molia -ErrorAction SilentlyContinue | Stop-Process -Force

$json = Join-Path $OutDir 'memory.jsonl'
$rows | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content -Encoding utf8 $json
Write-Host "[mem] 结果：$json"
