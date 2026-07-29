@echo off
setlocal
cd /d "%~dp0"
REM Opens the full page in your browser, starting the little server if needed.
REM
REM It refuses rather than guessing: if Node is missing you get told why, and if
REM port 8779 already belongs to some other program we do NOT open it and let you
REM believe it is Riah To-Do.

where node >nul 2>&1
if errorlevel 1 (
  echo.
  echo   The board needs Node.js, and it is not installed.
  echo.
  echo   The note by the clock does NOT need it - only this page does.
  echo   Get Node from https://nodejs.org, then run this again.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$c = Get-NetTCPConnection -LocalPort 8779 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if (-not $c) { exit 0 }; $p = Get-CimInstance Win32_Process -Filter \"ProcessId=$($c.OwningProcess)\" -ErrorAction SilentlyContinue; if ($p -and $p.CommandLine -like '*server.mjs*' -and $p.CommandLine -like '*Riah To-Do*') { exit 0 }; Write-Host ''; Write-Host '  Port 8779 is being used by another program:'; Write-Host ('    ' + $(if ($p) { $p.Name } else { 'unknown program' })); Write-Host ''; Write-Host '  Riah To-Do will not open that page, in case it is not ours.'; Write-Host '  Close that program, or set RIAH_TODO_PORT to a free port.'; Write-Host ''; exit 1"
if errorlevel 1 (
  pause
  exit /b 1
)

wscript.exe //B //Nologo "%~dp0start-hidden.vbs"
timeout /t 2 /nobreak >nul
start "" "http://127.0.0.1:8779/"
exit /b 0
