param(
  [string]$Exe = 'C:\Users\Still\molia-perf\build\windows\x64\runner\Release\molia.exe',
  [string]$OutDir = 'C:\Users\Still\AppData\Local\Temp\molia-perf',
  [int]$IdleSeconds = 5,
  [int]$ScrollSeconds = 6,
  [int]$WheelSteps = 40
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Get-Process molia -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

# 收藏页会持久化滚动位置：清零后再启动，保证每轮都从列表顶部开始；
# 否则第二轮就在底部，滚轮不再产生新行 / 新封面，帧数据不可比。
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

$stdout = Join-Path $OutDir 'frames-release.log'
$stderr = Join-Path $OutDir 'frames-release.err.log'
Remove-Item -Force $stdout, $stderr -ErrorAction SilentlyContinue

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MoliaWin32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@

[MoliaWin32]::SetProcessDPIAware() | Out-Null

$p = Start-Process -FilePath $Exe `
  -WorkingDirectory (Split-Path $Exe) `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError $stderr `
  -PassThru

Add-Type -AssemblyName System.Drawing
function Save-WindowShot([string]$Path) {
  $rect = New-Object MoliaWin32+RECT
  [MoliaWin32]::GetWindowRect($handle, [ref]$rect) | Out-Null
  $bmp = New-Object System.Drawing.Bitmap ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose()
  $bmp.Dispose()
}

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

[MoliaWin32]::SetForegroundWindow($handle) | Out-Null
$wshell = New-Object -ComObject WScript.Shell
$wshell.AppActivate($p.Id) | Out-Null
Start-Sleep -Seconds 1
[MoliaWin32]::SetForegroundWindow($handle) | Out-Null

# 启动首页由体检脚本预先写成 favorites；不再依赖 Ctrl+3（前台焦点在
# Windows 上不总是可靠，切换失败会把歌词页当成收藏页测）。
Start-Sleep -Seconds 2

$rect = New-Object MoliaWin32+RECT
[MoliaWin32]::GetWindowRect($handle, [ref]$rect) | Out-Null
$cx = [int](($rect.Left + $rect.Right) / 2)
$cy = [int](($rect.Top + $rect.Bottom) / 2)
[MoliaWin32]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Seconds 2
Save-WindowShot (Join-Path $OutDir 'frames-pre-scroll.png')

Write-Host "[perf] idle ${IdleSeconds}s"
Start-Sleep -Seconds $IdleSeconds

Write-Host "[perf] wheel scroll ${ScrollSeconds}s ($WheelSteps steps)"
$scrollDeadline = (Get-Date).AddSeconds($ScrollSeconds)
while ((Get-Date) -lt $scrollDeadline) {
  for ($i = 0; $i -lt $WheelSteps; $i++) {
    [MoliaWin32]::mouse_event(0x0800, 0, 0, -120, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
  }
}
Save-WindowShot (Join-Path $OutDir 'frames-post-scroll.png')

Start-Sleep -Seconds 6
Get-Process molia -ErrorAction SilentlyContinue | Stop-Process -Force

$frames = Join-Path $OutDir 'frames.log'
Select-String -Path $stdout -Pattern 'molia\.frame' |
  ForEach-Object { $_.Line } | Set-Content -Encoding utf8 $frames
Write-Host "[perf] 帧日志：$frames"
Get-Content $frames | Select-Object -Last 10
