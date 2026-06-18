' launch-hidden.vbs - Launches AltTabSucksServer.ps1 with no console window.
' Used as the Task Scheduler action so the server is always hidden regardless of
' Windows version or Group Policy behavior around -WindowStyle Hidden.
' The True (wait=True) keeps wscript.exe alive while the server runs so Task Scheduler
' can track the task state and restart it if it crashes.
Dim shell, scriptDir
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File """ & scriptDir & "\AltTabSucksServer.ps1""", 0, True
