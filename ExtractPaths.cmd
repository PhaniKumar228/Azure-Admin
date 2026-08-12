@echo off
setlocal EnableDelayedExpansion

set "InputFile=LincolnNational.ini"
set "OutputFile=PathDetails.txt"

if exist "%OutputFile%" del "%OutputFile%"

for /f "usebackq delims=" %%L in ("%InputFile%") do (
    set "line=%%L"

    echo !line! | findstr /r "^\[.*\]$" >nul
    if !errorlevel! == 0 (
        set "section=!line!"
    )

    echo !line! | find "\" >nul
    if !errorlevel! == 0 (
        echo !section! - !line!>>"%OutputFile%"
    )
)

echo Done. Output saved to %OutputFile%
