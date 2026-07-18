@echo off
setlocal EnableDelayedExpansion

set "FILELIST=ScriptList.txt"
set "LOG=Changes.log"

echo ===================================== > "%LOG%"
echo Started %DATE% %TIME% >> "%LOG%"
echo ===================================== >> "%LOG%"

:: Count files
set TOTAL=0
for /f "usebackq delims=" %%A in ("%FILELIST%") do (
    set /a TOTAL+=1
)

echo Total Files: !TOTAL!
echo.

set COUNT=0

for /f "usebackq delims=" %%A in ("%FILELIST%") do (

    set /a COUNT+=1

    echo [!COUNT!/!TOTAL!] Processing:
    echo %%A

    if exist "%%A" (
        cscript //nologo ReplaceInFile.vbs "%%A" "%LOG%"
    ) else (
        echo %DATE% %TIME% ^| NOT FOUND ^| %%A >> "%LOG%"
        echo [!COUNT!/!TOTAL!] NOT FOUND
    )

    timeout /t 1 /nobreak >nul
)

echo ===================================== >> "%LOG%"
echo Finished %DATE% %TIME% >> "%LOG%"

echo.
echo Completed !TOTAL! files
echo Log File: %LOG%
pause
