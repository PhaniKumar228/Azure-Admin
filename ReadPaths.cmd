@echo off
setlocal EnableDelayedExpansion

set "INPUTFILE=%~1"
set "OUTPUTFILE=SharePaths.txt"

echo Input File: %INPUTFILE%

if not exist "%INPUTFILE%" (
    echo ERROR: File not found or access denied.
    pause
    exit /b 1
)

if exist "%OUTPUTFILE%" del "%OUTPUTFILE%"

echo =====================================
echo Processing %~nx1
echo =====================================

set FOUND=0

for /f "usebackq delims=" %%L in ("%INPUTFILE%") do (
    echo %%L | findstr "\\\\" >nul

    if not errorlevel 1 (
        echo %%L
        echo %%L>>"%OUTPUTFILE%"
        set FOUND=1
    )
)

echo.

if !FOUND! EQU 1 (
    echo %~nx1 DONE
    echo Results saved to %OUTPUTFILE%
) else (
    echo %~nx1 NO_PATH_FOUND
    echo No UNC paths found>"%OUTPUTFILE%"
)

pause
