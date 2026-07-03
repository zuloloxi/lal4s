@echo off
rem ============================================================
rem runtests.bat  —  parse a lal4s test-run log, set exit code
rem ============================================================
rem Usage:
rem   runtests.bat [logfile]
rem
rem Default logfile = lal4s_debug.log.
rem
rem Workflow:
rem   1. Launch a snippet test set, e.g.:
rem        lal4s.exe tests\smoke.txt
rem   2. Press the test snippet's hotkey (e.g. Ctrl+Shift+B).
rem   3. Exit lal4s.exe.
rem   4. Run:
rem        runtests.bat
rem
rem Exit codes:
rem   0  all tests passed (no FAIL: lines, [TEST RUN] present)
rem   1  one or more FAIL: lines found
rem   2  no [TEST RUN] summary — test didn't fire
rem   3  logfile missing
rem ============================================================

setlocal

set "LOGFILE=%~1"
if "%LOGFILE%"=="" set "LOGFILE=lal4s_debug.log"

if not exist "%LOGFILE%" (
    echo runtests: log file not found: %LOGFILE%
    exit /b 3
)

findstr /C:"[TEST RUN]" "%LOGFILE%" > nul
if errorlevel 1 (
    echo runtests: no [TEST RUN] summary in %LOGFILE%
    echo runtests: did the test snippet fire? press its hotkey before exiting lal4s.
    exit /b 2
)

findstr /C:"FAIL:" "%LOGFILE%" > nul
if errorlevel 1 (
    echo runtests: ALL PASS  ^(log: %LOGFILE%^)
    findstr /C:"[TEST RUN]" "%LOGFILE%"
    exit /b 0
)

echo runtests: FAILURES in %LOGFILE%
echo.
findstr /C:"FAIL:" "%LOGFILE%"
echo.
findstr /C:"[TEST RUN]" "%LOGFILE%"
exit /b 1
