@echo off
setlocal DisableDelayedExpansion
rem Use Windows PowerShell 5.1, independent of PATH, profiles and working directory.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\ProjectBootstrap.ps1" %*
set "BootstrapExit=%ERRORLEVEL%"
if "%BootstrapExit%"=="0" exit /b 0
echo.
echo Project setup stopped (code %BootstrapExit%). See the explanation and log path above.
pause
exit /b %BootstrapExit%
