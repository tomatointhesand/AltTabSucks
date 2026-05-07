@echo off
where pwsh >nul 2>nul
if %errorlevel% neq 0 (
    echo PowerShell 7 ^(pwsh^) is required but not installed.
    echo.
    echo Install it by running this in a command prompt:
    echo   winget install Microsoft.PowerShell
    echo.
    echo Then double-click Install.bat again.
    pause
    exit /b 1
)
pwsh -ExecutionPolicy Bypass -File "%~dp0installer.ps1"
pause
