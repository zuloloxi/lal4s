@echo off
rem ===========================================================================
rem  run_weblog_test.bat - one-shot local CDP/weblog test harness.
rem    1. starts the Node test web server (http://localhost:8722)
rem    2. launches lal4s.exe with tests\weblog_probe.txt
rem    3. you press Ctrl+Shift+F7 to run the probe; results -> lal4s_debug.log
rem  Needs Node on PATH and helpers.dll present (both already here).
rem ===========================================================================
setlocal
cd /d "%~dp0"

echo Starting local test web server on http://localhost:8722 ...
start "lal4s test web server (close window to stop)" cmd /k node "%~dp0tests\webserver\server.js"

rem let the server bind the port
timeout /t 2 /nobreak >nul

echo Launching lal4s.exe (loads tests\weblog_probe.txt) ...
start "" "%~dp0lal4s.exe" "tests\weblog_probe.txt"

echo.
echo ---------------------------------------------------------------------------
echo  Ready.  Now:
echo    1. Press  Ctrl+Shift+F7   to run the weblog probe
echo         (launches Edge on debug port 9222, evals against good.html).
echo    2. Results append to  %~dp0lal4s_debug.log
echo.
echo  Press any key to tail the log live in this window (Ctrl+C to stop).
echo  When done: close the server window and Exit lal4s from its tray icon.
echo ---------------------------------------------------------------------------
pause >nul

if not exist "%~dp0lal4s_debug.log" (
    echo lal4s_debug.log not created yet - is lal4s running? Press a key to retry.
    pause >nul
)
powershell -NoProfile -Command "Get-Content -LiteralPath '%~dp0lal4s_debug.log' -Wait -Tail 100"
