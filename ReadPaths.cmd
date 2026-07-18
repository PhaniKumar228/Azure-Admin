@echo off
setlocal EnableDelayedExpansion

set "INPUTFILE=%~1"
set "OUTPUTFILE=SharePaths.txt"

if "%INPUTFILE%"=="" (
    echo Usage: ReadPaths.cmd "UNC_File_Path"
    exit /b 1
)

if not exist "%INPUTFILE%" (
    echo %~nx1 FAILED - File not found
    exit /b 1
)

REM Create output file only once
if not exist "%OUTPUTFILE%" (
    echo ==== Share Path Report ==== > "%OUTPUTFILE%"
)

echo.
echo Processing: %~nx1
echo ---------------------------------

set FOUND=0

for /f "usebackq delims=" %%L in ("%INPUTFILE%") do (
    echo %%L | findstr "\\\\" >nul
    if not errorlevel 1 (
        echo %%L
        echo [%~nx1] %%L>>"%OUTPUTFILE%"
        set FOUND=1
    )
)

if !FOUND! EQU 1 (
    echo %~nx1 DONE
    echo [%date% %time%] %~nx1 DONE>>"%OUTPUTFILE%"
) else (
    echo %~nx1 NO_PATH_FOUND
    echo [%date% %time%] %~nx1 NO_PATH_FOUND>>"%OUTPUTFILE%"
)

echo.
