@echo off
cd /d "%~dp0"
call "%~dp0_config.bat"
if not exist "%TOOLS%" mkdir "%TOOLS%"
set "SRC=C:\Users\Juegos\Downloads\iPhone12.1\tools"
if not exist "%SRC%\irecovery.exe" (
  echo No encuentro %SRC%\irecovery.exe
  echo Copia manualmente a %TOOLS%:
  echo   irecovery.exe iproxy.exe Usbliter8Boot.exe *.dll
  pause
  exit /b 1
)
echo Copiando herramientas USB a %TOOLS% ...
copy /Y "%SRC%\irecovery.exe" "%TOOLS%\" >nul
copy /Y "%SRC%\iproxy.exe" "%TOOLS%\" >nul
if exist "%SRC%\Usbliter8Boot.exe" copy /Y "%SRC%\Usbliter8Boot.exe" "%TOOLS%\" >nul
for %%D in (%SRC%\*.dll) do copy /Y "%%D" "%TOOLS%\" >nul 2>nul
echo.
echo Opcional usbliter8 jump ^(solo archivo bin, no pack Aaron^):
if exist "%SRC%\..\iBoot.patched.bin" copy /Y "%SRC%\..\iBoot.patched.bin" "%TOOLS%\" >nul
echo Hecho.
pause
