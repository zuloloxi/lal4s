@echo off
rem Start the cf22 local test web server (default port 8722).
rem Usage: start.bat [port]
node "%~dp0server.js" %*
