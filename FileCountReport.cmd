@echo off
setlocal enabledelayedexpansion

:: ===== INPUT ======
set "BASE=D:\Your\Base\Folder"
set "OUTPUT=D:\FileReport.txt"

:: Clear old output
if exist "%OUTPUT%" del "%OUTPUT%"

:: Temp file
set "TEMPFILE=%TEMP%\filelist.tmp"
if exist "%TEMPFILE%" del "%TEMPFILE%"

:: Get all files
dir "%BASE%" /s /b /a-d > "%TEMPFILE%"

:: Process each file
for /f "delims=" %%F in (%TEMPFILE%) do (
    set "full=%%F"

    :: Remove base path
    set "rel=!full:%BASE%\=!"

    :: Extract folder and subfolder
    for /f "tokens=1,2 delims=\" %%A in ("!rel!") do (
        set "folder=%%A"
        set "subfolder=%%B"
    )

    if "!folder!"=="" set "folder=Root"
    if "!subfolder!"=="" set "subfolder=NA"

    :: Get extension
    for %%E in ("%%F") do set "ext=%%~xE"
    set "ext=!ext:~1!"

    :: Write temp normalized data
    echo !folder!^|!subfolder!^|!ext! >> "%OUTPUT%"
)

:: ===== COUNT LOGIC =====
echo Processing counts...

sort "%OUTPUT%" > "%OUTPUT%.sorted"

:: Count occurrences
set "PREV="
set COUNT=0

(for /f "delims=" %%L in (%OUTPUT%.sorted) do (
    if "%%L"=="!PREV!" (
        set /a COUNT+=1
    ) else (
        if defined PREV echo !PREV! - !COUNT!
        set "PREV=%%L"
        set COUNT=1
    )
)
if defined PREV echo !PREV! - !COUNT!) > "%OUTPUT%.final"

:: Clean formatting
for /f "tokens=1-3 delims=|" %%A in (%OUTPUT%.final) do (
    echo %%A - %%B - %%C
) > "%OUTPUT%"

:: Cleanup
del "%TEMPFILE%" "%OUTPUT%.sorted" "%OUTPUT%.final"

echo ✅ Report generated: %OUTPUT%
pause
