@echo off
setlocal EnableDelayedExpansion

set "INPUT=ReadPaths.txt"
set "LOG=ExecutionResults.txt"

for /f "usebackq delims=" %%A in ("%INPUT%") do (

    if exist "%%A" (
        call "%%A" >nul 2>&1

        if !errorlevel! EQU 0 (
            echo %%A,DONE>>"%LOG%"
        ) else (
            echo %%A,FAILED>>"%LOG%"
        )
    ) else (
        echo %%A,NOT_FOUND>>"%LOG%"
    )
)

echo Completed.
