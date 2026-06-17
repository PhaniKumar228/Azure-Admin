@echo off
setlocal enabledelayedexpansion

set "BASE=\\aws-jup\test"
set "OUT=%BASE%\All_File_Count.txt"

if exist "%OUT%" del "%OUT%"

:: Temp files
set "TEMP1=%TEMP%\all_files.txt"
set "TEMP2=%TEMP%\folder_ext.txt"
set "SORTED=%TEMP%\sorted.txt"

:: Step 1: Get all files
dir "%BASE%" /s /b /a-d > "%TEMP1%"

:: Step 2: Extract folder path + extension
(for /f "delims=" %%F in (%TEMP1%) do (
    set "ext=%%~xF"
    echo %%~dpF^|!ext!
)) > "%TEMP2%"

:: Step 3: Sort data
sort "%TEMP2%" > "%SORTED%"

:: Step 4: Count occurrences
set "prev="
set count=0

(for /f "delims=" %%A in (%SORTED%) do (
    if "%%A"=="!prev!" (
        set /a count+=1
    ) else (
        if defined prev (
            for /f "tokens=1,2 delims=|" %%X in ("!prev!") do (
                echo %%X, %%Y, !count!
            )
        )
        set "prev=%%A"
        set count=1
    )
)

:: Last entry
if defined prev (
    for /f "tokens=1,2 delims=|" %%X in ("!prev!") do (
        echo %%X, %%Y, !count!
    )
) >> "%OUT%"

:: Cleanup
del "%TEMP1%" "%TEMP2%" "%SORTED%"

echo ✅ Output generated: %OUT%
pause
