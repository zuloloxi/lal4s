@echo off
rem ===========================================================================
rem  run_web_tests.bat - local CDP test suite + pass/fail scoring.
rem    1. starts the Node test web server (http://localhost:8722)
rem    2. launches lal4s.exe with tests\web_local_tests.txt
rem    3. you press Ctrl+Shift+W to run the 4-test suite
rem    4. runtests.bat greps lal4s_debug.log and sets the exit code
rem       (0 = all pass, 1 = a FAIL:, 2 = suite did not run, 3 = no log)
rem  Needs Node on PATH and helpers.dll present (both already here).
rem ===========================================================================
setlocal
cd /d "%~dp0"

rem fresh log so runtests only scores this run
del /q "%~dp0lal4s_debug.log" 2>nul

echo Starting local test web server on http://localhost:8722 ...
start "lal4s test web server (close window to stop)" cmd /k node "%~dp0tests\webserver\server.js"

timeout /t 2 /nobreak >nul

echo Launching lal4s.exe (loads tests\web_local_tests.txt) ...
start "" "%~dp0lal4s.exe" "tests\web_local_tests.txt"

echo.
echo ---------------------------------------------------------------------------
echo  Now press  Ctrl+Shift+W  to run the web test suite.
echo  It takes ~15s (Edge connect on port 9222 + 4 tests + a 4-tick webwatch).
echo  Wait until it finishes, THEN press any key here to score the run.
echo ---------------------------------------------------------------------------
pause >nul

echo.
echo === Scoring lal4s_debug.log ===
call "%~dp0runtests.bat" "%~dp0lal4s_debug.log"
echo runtests exit code: %errorlevel%
echo.
echo Close the server window and Exit lal4s from its tray icon when done.
pause
