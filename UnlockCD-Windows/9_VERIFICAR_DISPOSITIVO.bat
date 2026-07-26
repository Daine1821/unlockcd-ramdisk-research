@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
set "PATH=%TOOLS%;%PATH%"
echo === irecovery -q ===
irecovery -q
if errorlevel 1 echo No hay USB DFU/Recovery
echo.
echo Device: %FW_DEVICE%
echo Universal: %FW_UNIV%
if exist "%FW_DEVICE%" (echo [OK] device) else (echo [!!] falta device FW)
pause
