@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
set "PATH=%TOOLS%;%PATH%"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=5 -p %SSH_PORT% %SSH_USER%@%SSH_HOST% "echo SSH_OK; uname -a; mount | head -5"
pause
