@echo off
setlocal EnableDelayedExpansion

set "INPUT=AllCommands.txt"
set "LOG=Results.txt"

:: Count total commands
set TOTAL=0
for /f "usebackq delims=" %%A in ("%INPUT%") do (
    set /a TOTAL+=1
)

echo ================================================== > "%LOG%"
echo Started: %DATE% %TIME% >> "%LOG%"
echo Total Scripts: !TOTAL! >> "%LOG%"
echo ================================================== >> "%LOG%"

set COUNT=0

for /f "usebackq delims=" %%A in ("%INPUT%") do (

    set /a COUNT+=1

    echo.
    echo [!COUNT!/!TOTAL!] Running:
    echo %%A

    call %%A

    if !ERRORLEVEL! EQU 0 (
        echo [!COUNT!/!TOTAL!] DONE - %%A
        echo DONE,%%A >> "%LOG%"
    ) else (
        echo [!COUNT!/!TOTAL!] FAILED - %%A
        echo FAILED,%%A >> "%LOG%"
    )

    timeout /t 1 /nobreak >nul
)

echo ================================================== >> "%LOG%"
echo Finished: %DATE% %TIME% >> "%LOG%"

echo.
echo All !TOTAL! commands processed.
echo Results saved to %LOG%
pause
