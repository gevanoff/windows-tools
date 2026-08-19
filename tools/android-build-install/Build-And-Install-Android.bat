@echo off
setlocal

if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -File "%~dp0Run-AndroidBuildInstall.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -File "%~dp0Run-AndroidBuildInstall.ps1" ^
        -Project "%~1"
)

set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo Android build/install tool finished.
) else (
    echo Android build/install tool exited with an error.
    echo A detailed log should have opened in Notepad.
)

echo.
pause
exit /b %EXIT_CODE%
