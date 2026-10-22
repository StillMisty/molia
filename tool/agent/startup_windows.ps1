param(
  [string]$Project = 'C:\Users\Still\molia-perf',
  [string]$Flutter = 'C:\Tools\flutter\bin\flutter.bat',
  [int]$Runs = 5,
  [string]$OutDir = 'C:\Users\Still\AppData\Local\Temp\molia-perf',
  [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Set-Location $Project

if (-not $NoBuild) {
  Write-Host '[perf] flutter build windows --release (MOLIA_PERF_TRACE=true)'
  & $Flutter build windows --release --dart-define=MOLIA_PERF_TRACE=true
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败：$LASTEXITCODE" }
}

$exe = Join-Path $Project 'build\windows\x64\runner\Release\molia.exe'
if (-not (Test-Path $exe)) {
  throw "找不到 Windows release 产物：$exe（先去掉 -NoBuild 构建）"
}

function Stop-Molia {
  Get-Process -Name molia -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
}

$rows = @()
for ($i = 1; $i -le $Runs; $i++) {
  Stop-Molia
  $stdout = Join-Path $OutDir "startup-run-$i.log"
  $stderr = Join-Path $OutDir "startup-run-$i.err.log"
  Remove-Item -Force $stdout, $stderr -ErrorAction SilentlyContinue

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $proc = Start-Process -FilePath $exe `
    -WorkingDirectory (Split-Path $exe) `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru

  $windowMs = $null
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline) {
    $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($null -eq $p) { break }
    $p.Refresh()
    if ($p.MainWindowHandle -ne 0) {
      $windowMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
      break
    }
    Start-Sleep -Milliseconds 50
  }

  $firstFrameMs = $null
  $firstDeadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $firstDeadline) {
    if (Test-Path $stdout) {
      $match = Select-String -Path $stdout -Pattern 'molia\.startup: 首帧：(\d+)ms' |
        Select-Object -Last 1
      if ($null -ne $match) {
        $firstFrameMs = [int]$match.Matches[0].Groups[1].Value
        break
      }
    }
    Start-Sleep -Milliseconds 100
  }
  $sw.Stop()

  Stop-Molia
  $row = [ordered]@{
    run = $i
    wall_ms = $windowMs
    first_frame_ms = $firstFrameMs
    total_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    log = $stdout
  }
  $rows += [pscustomobject]$row
  Write-Host ("[perf] run {0}/{1}: wall={2}ms first_frame={3}ms" -f `
    $i, $Runs, $windowMs, $firstFrameMs)
}

$json = Join-Path $OutDir 'startup.jsonl'
$rows | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content -Encoding utf8 $json
Write-Host "[perf] 结果：$json"
$first = $rows | Where-Object { $null -ne $_.first_frame_ms } |
  Sort-Object first_frame_ms
if ($first.Count -gt 0) {
  $mid = $first[[int][math]::Floor($first.Count / 2)].first_frame_ms
  Write-Host "[perf] 首帧中位：${mid}ms（样本 $($first.Count)）"
}
