@echo off
setlocal
cd /d "%~dp0"
REM Use this after changing the tray script -- one instance only, so the old one
REM has to go first.
call "%~dp0Stop Riah To-Do.bat"
timeout /t 1 /nobreak >nul
wscript.exe //B //Nologo "%~dp0tray\tray-hidden.vbs"
exit /b 0
