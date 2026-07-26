@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
set "PATH=%TOOLS%;%PATH%"
echo Montaje HFZ (remote_mount_dynamic.sh) — sin oblit, sin /mnt8
echo Requiere: BOOT + 2_SSH_PROXY.bat
echo.
type "%SCRIPTS%\remote_mount_dynamic.sh" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -p %SSH_PORT% %SSH_USER%@%SSH_HOST% sh -s
echo.
pause
