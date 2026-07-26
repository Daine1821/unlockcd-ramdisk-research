@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
call "%~dp0_config.bat"
set "PATH=%TOOLS%;%PATH%"
set "UCW_ROOT=%~dp0"

echo ============================================
echo  BOOT UnlockCD ramdisk - iPhone 11 (n104ap)
echo  DFU : irecovery -f ibss.raw  ^(pwned DFU -^> Recovery^)
echo  REC : boot_order.json del pack, tal cual
echo ============================================

if not exist "%TOOLS%\irecovery.exe" (
  echo ERROR: falta %TOOLS%\irecovery.exe  -- SETUP_TOOLS.bat
  pause & exit /b 1
)
if not exist "%FW_DEVICE%\boot_order.json" (
  echo ERROR: falta %FW_DEVICE%\boot_order.json
  pause & exit /b 1
)
if not exist "%FW_UNIV%\26.1.dmg" (
  echo ERROR: falta %FW_UNIV%\26.1.dmg  -- DESENPAQUETAR_RAMDISKS.bat
  pause & exit /b 1
)
if not exist "%FW_DEVICE%\ibss.raw" (
  echo ERROR: falta %FW_DEVICE%\ibss.raw  ^(iBoot raw parcheado de UnlockCD^)
  pause & exit /b 1
)

irecovery -q
if errorlevel 1 (
  echo ERROR: no hay dispositivo USB
  pause & exit /b 1
)

call :is_recovery && goto gotrec

irecovery -q | find /I "MODE: DFU" >nul || (
  echo ERROR: se esperaba DFU pwned o Recovery
  pause & exit /b 1
)
irecovery -q | find /I "usbliter" >nul || (
  echo ERROR: DFU sin PWND usbliter8
  pause & exit /b 1
)

echo.
echo === Fase DFU: ibss.raw ^(verificado: pwned DFU -^> Recovery^) ===
irecovery -f "%FW_DEVICE%\ibss.raw"
if errorlevel 1 (
  call :is_recovery && goto gotrec
  echo ERROR subiendo ibss.raw
  irecovery -q
  pause & exit /b 1
)

echo Esperando Recovery (hasta 90s)...
call :wait_recovery 90 || (
  echo NO entro en Recovery tras ibss.raw
  irecovery -q
  pause & exit /b 2
)

:gotrec
echo.
echo Recovery OK
irecovery -q | find /I "MODE:"
timeout /t 2 /nobreak >nul
py -3 "%SCRIPTS%\run_boot_order.py"
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
  echo.
  echo Kernel arrancado. Espera 30-60s a que el ramdisk abra SSH y luego:
  echo   2_SSH_PROXY.bat   y en otra ventana   3_SSH_CONECTAR.bat
  echo   4_MOUNT.bat cuando SSH responda
  pause & exit /b 0
)

echo.
echo FALLO en la fase Recovery ^(codigo %RC%^).
echo Para ver el error real de iBoot:  irecovery -s   y escribe: bootx
irecovery -q
pause
exit /b %RC%

:is_recovery
irecovery -q 2>nul | find /I "MODE: Recovery" >nul
exit /b %ERRORLEVEL%

:wait_recovery
set /a N=0
:wr
set /a N+=1
if !N! GTR %~1 exit /b 1
call :is_recovery && exit /b 0
timeout /t 1 /nobreak >nul
goto wr
