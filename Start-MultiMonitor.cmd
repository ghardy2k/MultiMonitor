@echo off
rem Starts the MultiMonitor agent and opens the dashboard in your browser.
rem Extra arguments are passed through, e.g.  Start-MultiMonitor.cmd -Port 9000
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MultiMonitor.ps1" %*
if errorlevel 1 pause
