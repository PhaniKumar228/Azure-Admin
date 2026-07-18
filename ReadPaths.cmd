@echo off
setlocal EnableDelayedExpansion

REM Pass file name as parameter
set "INPUTFILE=%~1"
set "OUTPUTFILE=SharePaths.txt"

if "%INPUTFILE%"=="" (
    echo Usage: ReadPaths.cmd FileName.cmd
    exit /b 1
)

if not exist "%INPUTFILE%" (
    echo File not found: %INPUTFILE%
    exit /b 1
)

echo =====================================
echo Processing: %INPUTFILE%
echo =====================================

if exist "%OUTPUTFILE%" del "%OUTPUTFILE%"

set FOUND=0

for /f "delims=" %%L in (%INPUTFILE%) do (
    echo %%L | findstr "\\\\" >nul
    if not errorlevel 1 (
        echo %%L | findstr /o "\\\\" >nul

        echo %%L
        echo %%L>>"%OUTPUTFILE%"

        set FOUND=1
    )
)

echo.

if !FOUND! EQU 1 (
    echo STATUS : DONE
    echo Results saved to %OUTPUTFILE%
) else (
    echo STATUS : NO PATH FOUND
    echo No UNC paths found.>"%OUTPUTFILE%"
)

pause
