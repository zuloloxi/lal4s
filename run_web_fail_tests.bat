@echo off
rem ===========================================================================
rem  run_web_fail_tests.bat - NEGATIVE CDP suite (vs the broken bad.html).
rem    1. starts the Node test web server (http://localhost:8722)
rem    2. launches lal4s.exe with tests\web_local_fail_tests.txt
rem    3. you press Ctrl+Shift+W to run the 3-test suite
rem    4. the tests are SUPPOSED to fail (they prove error-detection works),
rem       so runtests exit code 1 (FAIL: found) is the PASS condition here.
rem  Needs Node on PATH and helpers.dll present (both already here).
rem ===========================================================================
setlocal
cd /d "%~dp0"

del /q "%~dp0lal4s_debug.log" 2>nul

echo Starting local test web server on http://localhost:8722 ...
start "lal4s test web server (close window to stop)" cmd /k node "%~dp0tests\webserver\server.js"

timeout /t 2 /nobreak >nul

echo Launching lal4s.exe (loads tests\web_local_fail_tests.txt) ...
start "" "%~dp0lal4s.exe" "tests\web_local_fail_tests.txt"

echo.
echo ---------------------------------------------------------------------------
echo  Now press  Ctrl+Shift+W  to run the NEGATIVE suite against bad.html.
echo  These 3 tests are EXPECTED to FAIL - that means expect_no_console_errors /
echo  expect_no_net_failures / webwatch correctly caught the broken page.
echo  Wait ~15s for it to finish, THEN press any key here to score the run.
echo ---------------------------------------------------------------------------
pause >nul

echo.
echo === Scoring lal4s_debug.log (expecting 0 pass, 3 fail) ===
call "%~dp0runtests.bat" "%~dp0lal4s_debug.log"
set "RC=%errorlevel%"
echo.
if "%RC%"=="1" (
    echo VERDICT: PASS  - the negative suite caught the broken page as expected.
) else if "%RC%"=="0" (
    echo VERDICT: PROBLEM - no failures detected; the expect_no_* / webwatch checks
    echo          did NOT catch bad.html's errors. Investigate.
) else if "%RC%"=="2" (
    echo VERDICT: suite did not run - did you press Ctrl+Shift+W and let it finish?
) else (
    echo VERDICT: no log / error ^(runtests rc=%RC%^).
)
echo.
echo Close the server window and Exit lal4s from its tray icon when done.
pause
