@echo off
REM Double-click to put today's list by the clock. Nothing else needs to run.
cd /d "%~dp0"
wscript.exe //B //Nologo "%~dp0tray\tray-hidden.vbs"
exit /b 0
