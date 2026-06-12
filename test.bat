@echo off
REM 動作確認用: コンソールを表示したまま前面で常駐デーモンを実行する。
REM ウィンドウを別モニターへ Alt+Tab すると、そのモニター中心へカーソルが移動する。
REM 停止するには このウィンドウで Ctrl+C を押すか、ウィンドウを閉じる。
echo MonitorMouse をテスト起動します。停止は Ctrl+C。
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0MonitorMouse.ps1"
pause
