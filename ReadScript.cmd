@echo off
setlocal EnableDelayedExpansion

:: ====================================================
:: Configuration
:: ====================================================
set "INPUTLIST=FileList.txt"
set "OUTPUTCSV=Output.csv"
set "BASEPATH=\\aws-infkc1p01\Batch"

echo CmdFile,FolderPath,FileName,FullPath > "%OUTPUTCSV%"

:: ====================================================
:: Process each file from file list
:: ====================================================
for /f "usebackq delims=" %%F in ("%INPUTLIST%") do (

    set "SCRIPTFILE=%%F"

    :: Check if file exists
    if not exist "%%F" (
        echo "%%~nxF",N/A,N/A,File Not Found >> "%OUTPUTCSV%"
        goto :continue
    )

    :: Validate path
    echo %%F | find /I "%BASEPATH%" >nul

    if errorlevel 1 (
        echo "%%~nxF",N/A,N/A,Out of Path >> "%OUTPUTCSV%"
        goto :continue
    )

    :: Read file and extract UNC paths
    for /f "tokens=*" %%L in ('findstr /R "\\\\.*" "%%F"') do (

        set "LINE=%%L"

        :: Remove quotes
        set "LINE=!LINE:"=!"

        :: Split on spaces and check each token
        for %%P in (!LINE!) do (

            echo %%P | findstr /B "\\\\" >nul

            if not errorlevel 1 (

                echo "%%~nxF","%%~dpP","%%~nxP","%%P" >> "%OUTPUTCSV%"

            )
        )
    )

    :continue
)

echo.
echo Output generated:
echo %OUTPUTCSV%
pause
