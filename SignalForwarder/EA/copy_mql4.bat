@echo off
REM Copies all MQL4 files from the current directory to the Experts directory of the MT4 installations specified in the .env file.

setlocal enabledelayedexpansion

REM Path to .env file
set "ENV_FILE=..\forwarder\.env"

REM Check if .env file exists
if not exist "%ENV_FILE%" (
    echo Error: .env file not found at %ENV_FILE%
    exit /b 1
)

REM Read MT4_FOLDERS from .env and remove quotes if present
for /f "usebackq tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
    if /i "%%A"=="MT4_FOLDERS" set "MT4_FOLDERS=%%B"
)

if not defined MT4_FOLDERS (
    echo Error: MT4_FOLDERS not found in .env file
    exit /b 1
)

REM Remove any surrounding quotes from MT4_FOLDERS
if not "%MT4_FOLDERS:~0,1%"=="\"" goto :noquotes
set "MT4_FOLDERS=%MT4_FOLDERS:~1,-1%"
:noquotes

REM Split MT4_FOLDERS by comma and process each folder
for %%F in (%MT4_FOLDERS:,= %) do (
    setlocal enabledelayedexpansion
    set "FOLDER=%%F"
    set "FOLDER=!FOLDER: =!"
    if not exist "!FOLDER!" (
        echo Warning: MT4 folder does not exist: !FOLDER!
    ) else (
        set "EXPERTS_DIR=!FOLDER!\MQL4\Experts"
        if not exist "!EXPERTS_DIR!" (
            mkdir "!EXPERTS_DIR!"
        )
        echo Copying MQL4 files to !EXPERTS_DIR!
        for %%G in (*.mq4) do (
            copy "%%G" "!EXPERTS_DIR!\" >nul
            if errorlevel 1 (
                echo Error: Failed to copy %%G to !EXPERTS_DIR!
            )
        )
        echo Successfully copied MQL4 files to !EXPERTS_DIR!
    )
    endlocal
)

endlocal
