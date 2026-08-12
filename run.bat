@echo off
setlocal
cd /d "%~dp0"

if not exist bin-executables\app-win.exe (
  echo Binary not found. Building first...
  call build.bat
)

bin-executables\app-win.exe %*
