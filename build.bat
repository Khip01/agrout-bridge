@echo off
setlocal
cd /d "%~dp0"
echo Getting dependencies...
call dart pub get
echo Compiling...
call dart compile exe bin\agrout_bridge.dart -o bin-executables\app-win.exe
echo Done! Binary at bin-executables\app-win.exe
