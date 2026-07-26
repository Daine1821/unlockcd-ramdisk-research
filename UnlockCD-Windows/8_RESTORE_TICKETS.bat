@echo off
setlocal EnableExtensions
cd /d "%~dp0"
call "%~dp0_config.bat"
call "%~dp0_bash.bat"
if not defined BASH (
  echo Instala Git for Windows para restaurar desde ZIP.
  pause
  exit /b 1
)
if "%~1"=="" (
  echo Uso: %~nx0 ruta\tickets.zip
  set /p ZIPFILE="ZIP: "
) else set "ZIPFILE=%~1"
if not exist "%ZIPFILE%" ( echo No existe & pause & exit /b 1 )
echo Requiere: /mnt2 montado + 2_SSH_PROXY.bat
set "SSH_HOST=%SSH_HOST%"
set "SSH_PORT=%SSH_PORT%"
set "SSH_USER=%SSH_USER%"
set "SSH_PASS=alpine"
"%BASH%" -lc "cd '%SCRIPTS:/=\%' && ./restore_from_zip.sh '%ZIPFILE:/=\%'"
pause
