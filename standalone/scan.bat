@echo off
rem gz_asset scanner: drag folders onto this file to add them; double-click to rescan.
cd /d "%~dp0"
rem Use a portable python\ folder next to this file if present, otherwise the system Python.
set "PY=%~dp0python\python.exe"
if not exist "%PY%" set "PY=python"
"%PY%" --version >nul 2>&1
if errorlevel 1 (
  echo Python not found. Install Python 3 from python.org, or put a portable python\ folder next to scan.bat.
  pause
  exit /b 1
)
"%PY%" "%~dp0gz_scan.py" --index "%~dp0..\index" %*
pause
