@echo off
setlocal EnableDelayedExpansion

set "INPUTLIST=FileList.txt"
set "OUTPUTCSV=Output.csv"
set "BASEPATH=\\aws-infkc1p01\Batch"

echo FileName,Status> "%OUTPUTCSV%"

for /f "usebackq delims=" %%F in ("%INPUTLIST%") do (

    set "FILE=%%F"

    REM Skip blank lines
    if "!FILE!"=="" (
        echo BlankLine,EMPTY>>"%OUTPUTCSV%"
        echo EMPTY
    ) else (

        if not exist "!FILE!" (
            echo %%~nxF,NOT_FOUND>>"%OUTPUTCSV%"
            echo %%~nxF FAILED
        ) else (

            echo !FILE! | find /I "%BASEPATH%" >nul

            if errorlevel 1 (
                echo %%~nxF,OUT_OF_PATH>>"%OUTPUTCSV%"
                echo %%~nxF FAILED
            ) else (

                echo %%~nxF,DONE>>"%OUTPUTCSV%"
                echo %%~nxF DONE
            )
        )
    )
)

echo Processing Completed.
pause
