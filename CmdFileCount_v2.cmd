@echo off
setlocal enabledelayedexpansion

set "BASE=\\aws-jup\test"
set "OUT=%BASE%\Cmd_File_Count.txt"

if exist "%OUT%" del "%OUT%"

:: Temp files
set "TEMP1=%TEMP%\cmd_list.txt"
set "TEMP2=%TEMP%\cmd_sorted.txt"

:: Step 1: Get all .cmd files
dir "%BASE%\*.cmd" /s /b /a-d > "%TEMP1%"

:: Step 2: Extract folder paths
(for /f "delims=" %%F in (%TEMP1%) do (
    echo %%~dpF
)) > "%TEMP2%"

:: Step 3: Sort paths
sort "%TEMP2%" > "%TEMP2%.sorted"

:: Step 4: Count per folder
set "prev="
set count=0

(for /f "delims=" %%A in (%TEMP2%.sorted) do (
    if "%%A"=="!prev!" (
        set /a count+=1
    ) else (
        if defined prev echo !prev!, .cmd, !count!
        set "prev=%%A"
        set count=1
    )
)
if defined prev echo !prev!, .cmd, !count!) > "%OUT%"

:: Cleanup
del "%TEMP1%" "%TEMP2%" "%TEMP2%.sorted"

echo ✅ Output generated: %OUT%
pause
``
