@echo off
setlocal EnableExtensions
cd /d "%~dp0"
echo [AION2] Debug launcher v1.6
set "AION2_FORCE_PREVIEW=1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1"
echo.
echo [AION2] PowerShell exited with code: %errorlevel%
echo Error log (if any): %LOCALAPPDATA%\AION2_Yustiel_Overlay\last_error.txt
pause
