@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
set "PATH=%TOOLS%;%PATH%"
echo Proxy SSH: localhost:%SSH_PORT% -^> device:22
echo En otra ventana: 3_SSH_CONECTAR.bat  o  ssh root@%SSH_HOST% -p %SSH_PORT%
echo Password: alpine
iproxy %SSH_PORT% 22
