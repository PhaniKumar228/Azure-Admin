@echo off
setlocal EnableDelayedExpansion

REM Configuration
set "FILELIST=C:\Ens_ReadScript\FileList.txt"
set "SOURCE=C:\SourceFiles"
set "DEST=C:\ProcessedFiles"

echo ======================================
echo Starting File Processing
echo ======================================

for /f "usebackq delims=" %%F in ("%FILELIST%") do (

    set "FILENAME=%%F"

    if exist "%SOURCE%\!FILENAME!" (

        echo Found: !FILENAME!
        move "%SOURCE%\!FILENAME!" "%DEST%\" >nul

        if !errorlevel! EQU 0 (
            echo SUCCESS: !FILENAME! moved.
        ) else (
            echo FAILED: !FILENAME! could not be moved.
        )

    ) else (
        echo MISSING: !FILENAME!
    )
)

echo.
echo Processing Complete.
pause
