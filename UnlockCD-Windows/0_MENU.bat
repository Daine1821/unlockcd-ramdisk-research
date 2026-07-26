@echo off
title UnlockCD Windows
cd /d "%~dp0"
:menu
cls
echo ============================================
echo  UnlockCD Ramdisk — Windows (como el .app)
echo ============================================
echo  1  BOOT UnlockCD DMG (ibss + boot_order.json)
echo  2  SSH proxy (iproxy 2222)
echo  3  SSH conectar (ventana nueva)
echo  4  Montar NAND (/mnt2 HFZ)
echo  5  Montar + User (/mnt8)
echo  6  Backup activacion SIMPLE (3 archivos ZIP)
echo  7  Backup activacion COMPLETO (carpeta)
echo  8  Restaurar tickets ZIP (HFZ)
echo  9  Verificar dispositivo (irecovery)
echo  B  Restaurar backup COMPLETO (carpeta)
echo  A  Probar SSH rapido
echo  0  Salir
echo ============================================
choice /C 123456789BA0 /N /M "Opcion: "
if errorlevel 12 goto end
if errorlevel 11 goto ssh_test
if errorlevel 10 goto restore_full
if errorlevel 9 goto check
if errorlevel 8 goto restore
if errorlevel 7 goto backup_full
if errorlevel 6 goto backup_simple
if errorlevel 5 goto mount8
if errorlevel 4 goto mount
if errorlevel 3 goto ssh
if errorlevel 2 goto proxy
if errorlevel 1 goto boot
goto menu
:boot
call "%~dp01_BOOT.bat"
goto menu
:proxy
start "iproxy" cmd /k "%~dp02_SSH_PROXY.bat"
goto menu
:ssh
call "%~dp03_SSH_CONECTAR.bat"
goto menu
:mount
call "%~dp04_MOUNT.bat"
goto menu
:mount8
call "%~dp05_MOUNT_CON_USER.bat"
goto menu
:backup_simple
call "%~dp06_BACKUP_ACTIVACION_SIMPLE.bat"
goto menu
:backup_full
call "%~dp07_BACKUP_ACTIVACION_COMPLETO.bat"
goto menu
:restore
call "%~dp08_RESTORE_TICKETS.bat"
goto menu
:restore_full
call "%~dp011_RESTORE_BACKUP_COMPLETO.bat"
goto menu
:check
call "%~dp09_VERIFICAR_DISPOSITIVO.bat"
goto menu
:ssh_test
call "%~dp010_SSH_TEST.bat"
goto menu
:end
exit /b 0
