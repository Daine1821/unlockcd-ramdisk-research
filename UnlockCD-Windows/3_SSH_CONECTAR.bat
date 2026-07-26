@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
set "PATH=%TOOLS%;%PATH%"
echo Conectando a %SSH_USER%@%SSH_HOST%:%SSH_PORT%  password: alpine
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -p %SSH_PORT% %SSH_USER%@%SSH_HOST%
