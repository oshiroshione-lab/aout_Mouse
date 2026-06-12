#requires -Version 5
<#
  自動起動の登録を解除し、現在動作中の常駐インスタンスを停止する。
#>
$ErrorActionPreference = 'Stop'

# スタートアップのショートカット削除
$startup = [Environment]::GetFolderPath('Startup')
$lnk     = Join-Path $startup 'MonitorMouse.lnk'
if (Test-Path $lnk) {
  Remove-Item $lnk -Force
  Write-Host "自動起動を解除: $lnk"
} else {
  Write-Host '自動起動の登録は見つかりませんでした。'
}

# 動作中インスタンスを停止
$stopped = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*MonitorMouse.ps1*' -and $_.CommandLine -notlike '*-Validate*' } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force; Write-Host "停止: PID $($_.ProcessId)"; $stopped++ } catch {}
  }
if ($stopped -eq 0) { Write-Host '動作中の常駐インスタンスはありませんでした。' }
Write-Host '完了。'
