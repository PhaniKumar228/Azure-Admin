@echo off
setlocal EnableDelayedExpansion

set "INPUTLIST=FileList.txt"
set "OUTPUTCSV=Output.csv"
set "BASEPATH=\\aws-infkc1p01\Batch"

echo CmdFile,FolderPath,FileName,FullPath>Status.csv

for /f "usebackq delims=" %%F in ("%INPUTLIST%") do (

    set "FILE=%%F"

    if not exist "%%F" (
        echo %%~nxF,N/A,N/A,File Not Found>>"%OUTPUTCSV%"
    ) else (

        echo %%F | find /I "%BASEPATH%" >nul

        if errorlevel 1 (
            echo %%~nxF,N/A,N/A,Out of Path>>"%OUTPUTCSV%"
        ) else (

            for /f "tokens=*" %%L in ('findstr "\\\\" "%%F"') do (

                for %%P in (%%L) do (

                    echo %%P|findstr /B "\\\\" >nul

                    if not errorlevel 1 (
                        echo %%~nxF,%%~dpP,%%~nxP,%%P>>"%OUTPUTCSV%"
                    )
                )
            )
        )
    )
)

echo Done.
pause
