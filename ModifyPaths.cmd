@echo off
setlocal EnableDelayedExpansion

set "FILELIST=ScriptList.txt"

set "BACKUPDIR=Before_18072026"
set "AFTERDIR=After_18072026"
set "LOG=Changes.log"

if not exist "%BACKUPDIR%" mkdir "%BACKUPDIR%"
if not exist "%AFTERDIR%" mkdir "%AFTERDIR%"

set TOTAL=0
for /f "usebackq delims=" %%A in ("%FILELIST%") do (
    set /a TOTAL+=1
)

echo Started %DATE% %TIME% > "%LOG%"

set COUNT=0

for /f "usebackq delims=" %%A in ("%FILELIST%") do (

    set /a COUNT+=1

    for %%F in ("%%A") do set "FILENAME=%%~nxF"

    echo [!COUNT!/!TOTAL!] Processing !FILENAME!

    if exist "%%A" (

        copy /Y "%%A" "%BACKUPDIR%\!FILENAME!" >nul

        powershell -NoProfile -Command ^
        "$c=Get-Content '%%A' -Raw;" ^
        "$c=$c -replace '\\\\infkc1p01\\','\\\\aws-infkc1p01\\';" ^
        "$c=$c -replace '\\\\pamuit\\','\\\\az-pamuit\\';" ^
        "$c=$c -replace '\\\\PAMstorage\\','\\\\aws-PAMstorage\\';" ^
        "Set-Content '%AFTERDIR%\!FILENAME!' $c"

        echo ==================================================>>"%LOG%"
        echo [!COUNT!/!TOTAL!] !FILENAME!>>"%LOG%"
        echo Source : %%A>>"%LOG%"
        echo Backup : %BACKUPDIR%\!FILENAME!>>"%LOG%"
        echo Output : %AFTERDIR%\!FILENAME!>>"%LOG%"

    ) else (
        echo NOT FOUND : %%A>>"%LOG%"
    )

    timeout /t 1 /nobreak >nul
)

echo Finished %DATE% %TIME% >> "%LOG%"
echo Completed.
pause
