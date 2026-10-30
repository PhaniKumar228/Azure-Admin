@echo off
setlocal enabledelayedexpansion

:: Check if folder path was provided
if "%~1"=="" (
    echo Usage: SearchLogs.cmd "C:\Logs"
    exit /b 1
)

set "LOGPATH=%~1"

if not exist "%LOGPATH%" (
    echo ERROR: Folder does not exist - %LOGPATH%
    exit /b 1
)

echo =====================================================
echo Searching under: %LOGPATH%
echo Looking for files containing BOTH:
echo   - invesco
echo   - national
echo =====================================================
echo.

set COUNT=0

for /r "%LOGPATH%" %%F in (*.log) do (
    findstr /i /m "invesco" "%%F" >nul
    if not errorlevel 1 (
        findstr /i /m "national" "%%F" >nul
        if not errorlevel 1 (
            echo MATCH: %%F
            set /a COUNT+=1
        )
    )
)

echo.
echo =====================================================
echo Total matching files: %COUNT%
echo Search completed.
echo =====================================================
pause
