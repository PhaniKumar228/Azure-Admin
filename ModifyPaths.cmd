@echo off
setlocal EnableDelayedExpansion

set "INPUT=ScriptList.txt"
set "BEFORE=Before_Modification.txt"
set "AFTER=After_Modification.txt"
set "LOG=PathChanges.txt"

del "%BEFORE%" 2>nul
del "%AFTER%" 2>nul
del "%LOG%" 2>nul

:: Count total lines
set TOTAL=0
for /f "usebackq delims=" %%A in ("%INPUT%") do (
    set /a TOTAL+=1
)

echo Total Records: !TOTAL!
echo.

set COUNT=0

for /f "usebackq delims=" %%A in ("%INPUT%") do (

    set /a COUNT+=1

    set "OLD=%%A"
    set "NEW=%%A"

    echo %%A>>"%BEFORE%"

    set "NEW=!NEW:\\infkc1p01\=\\aws-infkc1p01\!"
    set "NEW=!NEW:\\pamuit\=\\az-pamuit\!"
    set "NEW=!NEW:\\PAMstorage\=\\aws-PAMstorage\!"

    echo !NEW!>>"%AFTER%"

    (
        echo --------------------------------------------------
        echo Record: !COUNT!/!TOTAL!
        echo BEFORE: %%A
        echo AFTER : !NEW!
    )>>"%LOG%"

    echo [!COUNT!/!TOTAL!] Processed

    timeout /t 1 /nobreak >nul
)

echo.
echo Completed !TOTAL! records.
echo.
echo BEFORE FILE : %BEFORE%
echo AFTER FILE  : %AFTER%
echo CHANGE LOG  : %LOG%

pause
