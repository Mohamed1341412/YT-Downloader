@echo off
setlocal
cd /d "%~dp0"

set "SCRIPT=YT-Downloader.ps1"
set "SHELLEXE=powershell.exe"
if /i "%~1"=="pwsh" set "SHELLEXE=pwsh.exe"

REM بيانات اختبار معزولة (manifest وlogs وarchives). امسح السطر ده للاستخدام الحقيقي.
set "APPDATA=%~dp0TestAppData"

"%SHELLEXE%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Transcript -Path '%~dp0test-session.log' -Force | Out-Null; & '%~dp0%SCRIPT%'; Stop-Transcript | Out-Null"
echo.
echo Exit code: %ERRORLEVEL%
pause
