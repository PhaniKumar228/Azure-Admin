@echo off
setlocal EnableDelayedExpansion

set "INPUT=ScriptList.txt"
set "TARGET=\\aws-infkc1p01\batch\bkp_18072026"
set "LOG=CopyResults.txt"

if not exist "%TARGET%" (
    mkdir "%TARGET%"
)

:: Count files
set TOTAL=0
for /f "usebackq delims=" %%A in ("%INPUT%") do (
    set /a TOTAL+=1
)

echo ========================================= > "%LOG%"
echo Backup Started: %DATE% %TIME% >> "%LOG%"
echo Total Files: !TOTAL! >> "%LOG%"
echo ========================================= >> "%LOG%"

set COUNT=0

for /f "usebackq delims=" %%A in ("%INPUT%") do (

    set /a COUNT+=1

    set "SOURCE=%%A"

    :: Extract filename only
    for %%F in ("%%A") do set "FILENAME=%%~nxF"

    echo.
    echo [!COUNT!/!TOTAL!] Copying !FILENAME!

    if exist "%%A" (

        copy /Y "%%A" "%TARGET%\!FILENAME!" >nul

        if !ERRORLEVEL! EQU 0 (
            echo [!COUNT!/!TOTAL!] SUCCESS - !FILENAME!
            echo SUCCESS,!FILENAME! >> "%LOG%"
        ) else (
            echo [!COUNT!/!TOTAL!] FAILED - !FILENAME!
            echo FAILED,!FILENAME! >> "%LOG%"
        )

    ) else (
        echo [!COUNT!/!TOTAL!] NOT FOUND - !FILENAME!
        echo NOT_FOUND,!FILENAME! >> "%LOG%"
    )

    timeout /t 1 /nobreak >nul
)

echo ========================================= >> "%LOG%"
echo Backup Finished: %DATE% %TIME% >> "%LOG%"

echo.
echo Completed !TOTAL! files.
echo Results saved to %LOG%
pause
