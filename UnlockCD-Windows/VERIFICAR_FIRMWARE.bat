@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
echo Verificando universal %UNIVERSAL_MODEL% ...
if exist "%FW_UNIV%\26.1.dmg" (echo [OK] 26.1.dmg) else (echo [!!] Falta 26.1.dmg — vuelve a DESENPAQUETAR_RAMDISKS.bat)
if exist "%FW_UNIV%\26.1.dmg.trustcache" (echo [OK] trustcache) else (echo [!!] Falta 26.1.dmg.trustcache)
if exist "%FW_DEVICE%\kernelcache.release.iphone12b" (echo [OK] kernel) else (echo [!!] kernel device)
pause
