@echo off
rem UnlockCD Windows — rutas (sin pack Aaron)
set "UCW_ROOT=%~dp0"
set "RAMDISK_TOOL=%UCW_ROOT%.."
set "TOOLS=%UCW_ROOT%tools"
set "RAMDISK_MODEL=iPhone11_26.1"
set "UNIVERSAL_MODEL=universal_26.1"
set "FW_DEVICE=%RAMDISK_TOOL%\ramdisks_extracted\%RAMDISK_MODEL%\%RAMDISK_MODEL%"
set "FW_UNIV=%RAMDISK_TOOL%\ramdisks_extracted\%UNIVERSAL_MODEL%\%UNIVERSAL_MODEL%"
set "APP_RES=%RAMDISK_TOOL%\UnlockCD-Ramdisk-V1.0.app\Contents\Resources"
set "SCRIPTS=%UCW_ROOT%scripts"
set "BACKUPS=%UCW_ROOT%backups"
set "SSH_HOST=127.0.0.1"
set "SSH_PORT=2222"
set "SSH_USER=root"
rem UnlockCD: ramdisk/trustcache = universal_26.1 (26.1.dmg). Kernel/copro/SEP = iPhone11_26.1
rem Vacio = usar los boot-args que trae boot_order.json (rd=md0 nand-enable-reformat=1 -progress).
rem Solo rellena esto para probar otros boot-args, p.ej: rd=md0 -v serial=2 wdt=-1
set "UNLOCKCD_BOOT_ARGS="
