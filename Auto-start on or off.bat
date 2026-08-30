@echo off
setlocal
title QE AutoGear - auto-start
cd /d "%~dp0"

set "PY="
py -3 --version >nul 2>&1 && set "PY=py -3"
if not defined PY ( python --version >nul 2>&1 && set "PY=python" )
if not defined PY (
    echo.
    echo   Python is not installed yet.
    echo   Run "Run QE AutoGear.bat" first.
    echo.
    pause
    exit /b 1
)

echo.
echo   ==========================================
echo     QE AutoGear - start with Windows?
echo   ==========================================
echo.
%PY% tools\autostart.py
echo.
echo   [1] Turn it ON  - the helper starts by itself, minimised
echo   [2] Turn it OFF - you start it yourself each time
echo   [3] Leave it alone
echo.

choice /c 123 /n /m "  Pick 1, 2 or 3: "
echo.
if errorlevel 3 goto done
if errorlevel 2 goto off
if errorlevel 1 goto on

:on
%PY% tools\autostart.py --enable
goto done

:off
%PY% tools\autostart.py --disable
goto done

:done
echo.
pause
