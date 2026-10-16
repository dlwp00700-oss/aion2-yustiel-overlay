@echo off
setlocal
set "LOG=%LOCALAPPDATA%\AION2_Yustiel_Overlay\last_error.txt"
if exist "%LOG%" (notepad "%LOG%") else (
 echo No startup error file was created.
 echo Debug with the included debug .cmd launcher.
 pause
)
