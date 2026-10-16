Option Explicit
Dim sh, fs, baseDir, powerExe, bootstrap, command, env
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
baseDir = fs.GetParentFolderName(WScript.ScriptFullName)
powerExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
bootstrap = baseDir & "\bootstrap.ps1"
If Not fs.FileExists(powerExe) Or Not fs.FileExists(bootstrap) Then
  MsgBox "The PowerShell launcher or bootstrap.ps1 is missing.", vbCritical, "AION2 Yustiel"
  WScript.Quit 1
End If
Set env = sh.Environment("PROCESS")
env("AION2_FORCE_PREVIEW") = "1"
command = Chr(34) & powerExe & Chr(34) & " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & bootstrap & Chr(34)
On Error Resume Next
sh.Run command, 0, False
If Err.Number <> 0 Then MsgBox "AION2 preview failed: " & Err.Description, vbCritical, "AION2 Yustiel"
