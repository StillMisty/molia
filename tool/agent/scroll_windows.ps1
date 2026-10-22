param(
  [int]$Steps = 60,
  [int]$DelayMs = 25
)

$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MoliaScrollWin32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
[MoliaScrollWin32]::SetProcessDPIAware() | Out-Null

$p = Get-Process molia -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $p) { throw 'molia 未运行' }
$p.Refresh()
$handle = $p.MainWindowHandle
if ($handle -eq 0) { throw 'molia 窗口不存在' }

$wshell = New-Object -ComObject WScript.Shell
$wshell.AppActivate($p.Id) | Out-Null
Start-Sleep -Seconds 1
[MoliaScrollWin32]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Seconds 2

$rect = New-Object MoliaScrollWin32+RECT
[MoliaScrollWin32]::GetWindowRect($handle, [ref]$rect) | Out-Null
$cx = [int](($rect.Left + $rect.Right) / 2)
$cy = [int](($rect.Top + $rect.Bottom) / 2)
[MoliaScrollWin32]::SetCursorPos($cx, $cy) | Out-Null

for ($i = 0; $i -lt $Steps; $i++) {
  [MoliaScrollWin32]::mouse_event(0x0800, 0, 0, -120, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds $DelayMs
}
Write-Host "[scroll] done $Steps steps"
