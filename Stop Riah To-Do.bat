@echo off
setlocal
cd /d "%~dp0"
REM Closes the note by the clock and the board page server, if either is up.
REM Safe to double-click when nothing is running.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*-File*riah-todo-tray.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; $c = Get-NetTCPConnection -LocalPort 8779 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue }"
exit /b 0
