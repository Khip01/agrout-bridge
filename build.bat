@echo off
setlocal
cd /d "%~dp0"

:: Resolve package.json version for the compiled --version string.
for /f "tokens=*" %%i in ('node -p "require('./package.json').version"') do set VERSION=%%i

echo Getting dependencies...
call dart pub get
echo Compiling (PACKAGE_VERSION=%VERSION%)...
call dart compile exe bin\agrout_bridge.dart -o bin-executables\app-win.exe --dart-define=PACKAGE_VERSION="%VERSION%"
echo Done! Binary at bin-executables\app-win.exe (v%VERSION%)
