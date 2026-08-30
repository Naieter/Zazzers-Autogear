@echo off
setlocal enabledelayedexpansion
title QE AutoGear
cd /d "%~dp0"

echo.
echo   ==========================================
echo     QE AutoGear
echo   ==========================================
echo.

rem ---- 1. Find Python -------------------------------------------------
set "PY="
py -3 --version >nul 2>&1 && set "PY=py -3"
if not defined PY ( python --version >nul 2>&1 && set "PY=python" )

if not defined PY (
    echo   Python is not installed.
    echo.
    echo   Get it from:  https://www.python.org/downloads/
    echo   On the first screen of the installer, TICK the box that says
    echo   "Add python.exe to PATH", or this will not find it.
    echo.
    echo   Then run this file again.
    echo.
    pause
    exit /b 1
)
echo   [1/4] Python found.

rem ---- 2. Dependencies ------------------------------------------------
echo   [2/4] Checking helper libraries ^(first run takes a few minutes^)...
%PY% -m pip install --quiet --disable-pip-version-check -r agent\requirements.txt
if errorlevel 1 (
    echo.
    echo   Could not install the helper libraries.
    echo   Check your internet connection and run this file again.
    echo.
    pause
    exit /b 1
)

rem Downloads a private copy of Chrome. Harmless and quick if already there.
%PY% -m playwright install chromium >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Could not download the browser component.
    echo   Check your internet connection and run this file again.
    echo.
    pause
    exit /b 1
)

rem ---- 3. Install the addon into WoW ----------------------------------
echo   [3/4] Installing the addon into World of Warcraft...
%PY% tools\install.py --quiet
if errorlevel 1 (
    echo.
    echo   Could not find your World of Warcraft folder.
    echo   Open this file in Notepad and add your path to the line below,
    echo   then save and run it again. Example:
    echo.
    echo      %PY% tools\install.py --wow "D:\World of Warcraft\_retail_"
    echo.
    pause
    exit /b 1
)

rem ---- 4. Run --------------------------------------------------------
echo.
echo   [4/4] Ready.
echo.
echo   Leave this window open while you play.
echo   In the game, type:  /qeg run
echo.
echo   If you just installed the addon for the first time, close World of
echo   Warcraft completely and start it again so it notices the addon.
echo.
echo   ----------------------------------------------------------------
echo.

cd agent
%PY% -m qeagent

rem Only reached if the agent stops or crashes.
echo.
echo   The helper has stopped. Close this window, or run the file again.
echo.
pause
