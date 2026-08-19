@echo off
setlocal

if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -File "%~dp0Merge-GoogleDriveZips.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass ^
        -File "%~dp0Merge-GoogleDriveZips.ps1" ^
        -Source "%~1"
)

set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo The tool exited with an error.
)
pause
exit /b %EXIT_CODE%
