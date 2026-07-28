@echo off
setlocal
cd /d "%~dp0"
REM Opens the full page in your browser, starting the little server if needed.
wscript.exe //B //Nologo "%~dp0start-hidden.vbs"
timeout /t 2 /nobreak >nul
start "" "http://127.0.0.1:8779/"
exit /b 0
