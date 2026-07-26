@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
set "PATH=%TOOLS%;%PATH%"
echo Montaje HFZ + particion User en /mnt8
echo.
(
  echo export HFZ_MOUNT_USER=1
  echo export HFZ_SAFE_OBLIT=0
  type "%SCRIPTS%\remote_mount_dynamic.sh"
) | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -p %SSH_PORT% %SSH_USER%@%SSH_HOST% sh -s
echo.
pause
