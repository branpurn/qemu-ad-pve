@echo off
rem Offline torch install from the wheel disk (this CD). Usage: install-offline.cmd <venv dir>
rem Requires C:\gputest\py\python.exe (3.12). No network access is used (--no-index).
setlocal
set SRC=%~dp0wheelhouse
set VENV=%1
if "%VENV%"=="" set VENV=C:\gputest\venv-offline
if not exist "%VENV%\Scripts\python.exe" C:\gputest\py\python.exe -m venv "%VENV%" || exit /b 10
"%VENV%\Scripts\python.exe" -m pip install --no-index --find-links "%SRC%" torch==2.6.0+cu124 || exit /b 11
"%VENV%\Scripts\python.exe" -m pip list
