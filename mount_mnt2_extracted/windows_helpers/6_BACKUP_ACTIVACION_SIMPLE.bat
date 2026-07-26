@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
call "%~dp0_bash.bat"
if not defined BASH (
  echo Necesitas Git for Windows para este script.
  echo Instala Git o usa backup manual con scp desde SSH.
  pause
  exit /b 1
)
if not exist "%BACKUPS%" mkdir "%BACKUPS%"
echo Backup SIMPLE — 3 archivos en ZIP ^(como backup_activation_simple.sh^)
echo Requiere: /mnt2 montado + iproxy
echo.
set "SSH_HOST=%SSH_HOST%"
set "SSH_PORT=%SSH_PORT%"
set "SSH_USER=%SSH_USER%"
set "SSH_PASS=alpine"
"%BASH%" -lc "cd '%SCRIPTS:/=\%' && ./backup_activation_simple.sh '%BACKUPS:/=\%'"
pause
