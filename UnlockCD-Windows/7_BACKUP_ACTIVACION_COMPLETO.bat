@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
call "%~dp0_bash.bat"
if not defined BASH (
  echo Necesitas Git for Windows ^(bash^) para backup_activation.sh
  pause
  exit /b 1
)
if not exist "%BACKUPS%" mkdir "%BACKUPS%"
echo Backup COMPLETO — muchos paths Lockdown/FairPlay/etc.
echo Requiere ramdisk boot + iproxy. /mnt2 recomendado montado.
echo.
set "SSH_HOST=%SSH_HOST%"
set "SSH_PORT=%SSH_PORT%"
set "SSH_USER=%SSH_USER%"
set "SSH_PASS=alpine"
"%BASH%" -lc "cd '%APP_RES:/=\%' && ./backup_activation.sh backup '%BACKUPS:/=\%'"
pause
