@echo off
setlocal EnableExtensions

set "PKG_ROOT=%~dp0"
set "ENTRY_PS1=%PKG_ROOT%scripts\gnirehtet.ps1"

if not exist "%ENTRY_PS1%" (
    echo [ERROR] Missing entry script: "%ENTRY_PS1%"
    pause
    exit /b 2
)

set "PS_EXE="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
) else (
    where powershell.exe >nul 2>nul
    if %errorlevel%==0 (
        set "PS_EXE=powershell.exe"
    ) else (
        where pwsh.exe >nul 2>nul
        if %errorlevel%==0 set "PS_EXE=pwsh.exe"
    )
)

if "%PS_EXE%"=="" (
    echo [ERROR] PowerShell was not found on this system.
    pause
    exit /b 2
)

if "%~1"=="" (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%ENTRY_PS1%" -Action auto -PauseOnExit
    set "EXIT_CODE=%errorlevel%"
) else (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%ENTRY_PS1%" %*
    set "EXIT_CODE=%errorlevel%"
)

exit /b %EXIT_CODE%
