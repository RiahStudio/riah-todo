@echo off
setlocal
cd /d "%~dp0"
REM Closes the note by the clock and the board page server, if either is up.
REM Safe to double-click when nothing is running.
REM
REM The filter must exclude -Command shells and this process. A shell that merely
REM MENTIONS the script path (a stop command, a status check, an agent running a
REM one-liner) matches "*riah-todo-tray.ps1*" too, and killing those took out a
REM live session on 2026-07-29. Only a -File launch is the actual note.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$me = $PID; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -notlike '*-Command*' -and $_.CommandLine -like '*-File*riah-todo-tray.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; $c = Get-NetTCPConnection -LocalPort 8779 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $owner = Get-CimInstance Win32_Process -Filter \"ProcessId=$($c.OwningProcess)\" -ErrorAction SilentlyContinue; if ($owner -and $owner.CommandLine -like '*server.mjs*' -and $owner.CommandLine -like '*Riah To-Do*') { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } else { Write-Host 'Port 8779 belongs to something else - left alone.' } }"
exit /b 0
