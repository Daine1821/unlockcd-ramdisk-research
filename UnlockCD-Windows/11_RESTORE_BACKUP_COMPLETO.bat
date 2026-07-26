@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
call "%~dp0_bash.bat"
if not defined BASH ( echo Necesitas Git Bash & pause & exit /b 1 )
if "%~1"=="" (
  echo Uso: %~nx0 carpeta_backup\activation_backup_YYYYMMDD_HHMMSS
  set /p BDIR="Carpeta backup: "
) else set "BDIR=%~1"
if not exist "%BDIR%\file_list.txt" (
  echo No es backup valido ^(falta file_list.txt^)
  pause
  exit /b 1
)
set "SSH_HOST=%SSH_HOST%"
set "SSH_PORT=%SSH_PORT%"
set "SSH_USER=%SSH_USER%"
set "SSH_PASS=alpine"
"%BASH%" -lc "cd '%APP_RES:/=\%' && ./backup_activation.sh restore '%BDIR:/=\%'"
pause
