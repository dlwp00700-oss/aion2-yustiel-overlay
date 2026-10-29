Option Explicit
Dim sh, fs, baseDir, powerExe, bootstrap, command
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
baseDir = fs.GetParentFolderName(WScript.ScriptFullName)
powerExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
bootstrap = baseDir & "\bootstrap.ps1"
If Not fs.FileExists(powerExe) Then
  MsgBox "Windows PowerShell 5.1 not found.", vbCritical, "AION2 Yustiel"
  WScript.Quit 1
End If
If Not fs.FileExists(bootstrap) Then
  MsgBox "bootstrap.ps1 missing. Extract all files first.", vbCritical, "AION2 Yustiel"
  WScript.Quit 1
End If
command = Chr(34) & powerExe & Chr(34) & " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & bootstrap & Chr(34)
On Error Resume Next
sh.Run command, 0, False
If Err.Number <> 0 Then MsgBox "AION2 launch failed: " & Err.Description, vbCritical, "AION2 Yustiel"
