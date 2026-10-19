<#
.SYNOPSIS
  托盘内存采样（Windows）：专用工作集 / 提交大小。

.DESCRIPTION
  与 tool/agent/memory.sh 对齐的 Windows 版本。先启动应用（release 包或
  `flutter run -d windows`），再在另一个 PowerShell 里运行本脚本，然后在
  应用里关闭到托盘 / 从托盘唤起。

  任务管理器的「内存」列是专用工作集（WorkingSetPrivate），「提交大小」是
  PrivateBytes。托盘隐藏时应用会清图片缓存并调用 EmptyWorkingSet：工作集
  应立即下降，提交大小降幅约等于被清掉的图片缓存——见 docs/memory.md。

.PARAMETER Interval
  采样间隔（秒），默认 5。

.PARAMETER Timeout
  最长采样时长（秒），0 表示不限（Ctrl+C 结束）。

.PARAMETER ProcessId
  应用进程 id；默认取第一个 molia。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool/agent/memory.ps1 -Interval 2 -Timeout 120

.EXAMPLE
  pwsh tool/agent/memory.ps1 -ProcessId 12345
#>
param(
  [int]$Interval = 5,
  [int]$Timeout = 0,
  [int]$ProcessId = 0
)

if ($Interval -le 0) {
  throw 'Interval 必须大于 0'
}

if ($ProcessId -le 0) {
  $app = Get-Process -Name molia -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $app) {
    throw '找不到运行中的 molia：先 flutter run -d windows 或启动 release 包'
  }
  $ProcessId = $app.Id
}

# 专用工作集 = 任务管理器「内存」列。Get-Process 没有这个字段，走性能计数器；
# 计数器不可用时退回普通工作集（含共享页，数值略高）。
function Get-PrivateWorkingSet([int]$ProcId) {
  try {
    $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
      -Filter "IDProcess = $ProcId" -ErrorAction Stop |
      Select-Object -First 1
    if ($null -ne $perf -and $null -ne $perf.WorkingSetPrivate) {
      return [double]($perf.WorkingSetPrivate)
    }
  } catch {
    # 计数器服务被禁用 / 查询失败：交给调用方回退。
  }
  return $null
}

function Format-Mb([double]$Bytes) {
  return ('{0:N1}MB' -f ($Bytes / 1MB))
}

$samples = New-Object System.Collections.Generic.List[double]
$start = Get-Date
$duration = ''
if ($Timeout -gt 0) {
  $duration = "，最长 ${Timeout}s"
}
Write-Host "采样 PID $ProcessId，每 ${Interval}s 一次${duration}（Ctrl+C 结束）"

try {
  while ($true) {
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
      Write-Host "进程 $ProcessId 已退出"
      break
    }

    $wsPrivate = Get-PrivateWorkingSet $ProcessId
    $workingSet = [double]($proc.WorkingSet64)
    $commit = [double]($proc.PrivateMemorySize64)
    $primary = if ($null -ne $wsPrivate) { $wsPrivate } else { $workingSet }
    $samples.Add([double]$primary)

    $privateText = if ($null -ne $wsPrivate) {
      Format-Mb $wsPrivate
    } else {
      'n/a（回退普通工作集）'
    }
    Write-Host ('[{0}] 内存={1}（专用工作集） 提交={2} 工作集={3}' -f `
      (Get-Date -Format 'HH:mm:ss'), $privateText,
      (Format-Mb $commit), (Format-Mb $workingSet))

    if ($Timeout -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $Timeout) {
      break
    }
    Start-Sleep -Seconds $Interval
  }
} finally {
  if ($samples.Count -gt 0) {
    $sorted = @($samples | Sort-Object)
    $min = $sorted[0]
    $max = $sorted[$sorted.Count - 1]
    $half = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
      $median = $sorted[$half]
    } else {
      $median = ($sorted[$half - 1] + $sorted[$half]) / 2
    }
    Write-Host ('汇总：样本 {0}，min {1}，中位 {2}，max {3}' -f `
      $sorted.Count, (Format-Mb $min), (Format-Mb $median),
      (Format-Mb $max))
  } else {
    Write-Host '没有采到样本（进程在首个采样周期内退出？）'
  }
}
