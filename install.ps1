#requires -Version 5
<#
  ログイン時の自動起動を登録し、いますぐ常駐を開始する。
  - スタートアップフォルダ (shell:startup) に wscript.exe -> launch-hidden.vbs の
    ショートカットを作成する（管理者権限不要）。
  - 既存の登録があれば上書きする。
#>
$ErrorActionPreference = 'Stop'

$dir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs   = Join-Path $dir 'launch-hidden.vbs'
$psmain = Join-Path $dir 'MonitorMouse.ps1'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'

if (-not (Test-Path $vbs))    { throw "launch-hidden.vbs が見つかりません: $vbs" }
if (-not (Test-Path $psmain)) { throw "MonitorMouse.ps1 が見つかりません: $psmain" }

# 念のためコンパイル検証
Write-Host '[1/3] スクリプトのコンパイル検証...'
& powershell.exe -ExecutionPolicy Bypass -NoProfile -File $psmain -Validate
if ($LASTEXITCODE -ne 0) { throw 'MonitorMouse.ps1 のコンパイル検証に失敗しました。' }

# 既存インスタンスを停止
Write-Host '[2/3] 既存の常駐インスタンスを停止...'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*MonitorMouse.ps1*' -and $_.CommandLine -notlike '*-Validate*' } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force; Write-Host "  停止: PID $($_.ProcessId)" } catch {}
  }

# スタートアップにショートカット作成
$startup = [Environment]::GetFolderPath('Startup')
$lnk     = Join-Path $startup 'MonitorMouse.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath       = $wscript
$sc.Arguments        = '"' + $vbs + '"'
$sc.WorkingDirectory = $dir
$sc.WindowStyle      = 7
$sc.Description       = 'MonitorMouse - ウィンドウ切替時にカーソルをモニター中心へ'
$sc.Save()
Write-Host "[3/3] 自動起動を登録: $lnk"

# いますぐ起動
Start-Process -FilePath $wscript -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $dir
Write-Host ''
Write-Host '完了。常駐を開始しました。次回ログイン以降も自動起動します。'
Write-Host '停止/解除するには uninstall.ps1 を実行してください。'
