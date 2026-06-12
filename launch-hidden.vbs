' MonitorMouse.ps1 を完全に非表示（コンソール窓を出さず）で起動するランチャー。
' wscript.exe で実行されるため、このスクリプト自体も窓を出さない。
Dim sh, fso, scriptDir, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File """ & scriptDir & "\MonitorMouse.ps1"""
' 第2引数 0 = ウィンドウ非表示, 第3引数 False = 終了を待たない
sh.Run cmd, 0, False
