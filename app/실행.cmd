@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "WSCRIPT=%SystemRoot%\System32\wscript.exe"
if not exist "%WSCRIPT%" (echo Windows Script Host is not available.& pause & exit /b 1)
start "" "%WSCRIPT%" "%~dp0AION2_start.vbs"
exit /b 0
