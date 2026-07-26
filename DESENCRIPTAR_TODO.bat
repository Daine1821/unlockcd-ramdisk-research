@echo off
cd /d "%~dp0"
echo Descifrando scripts .enc (start, mnt2, give, restore) ...
py -3 "%~dp0decrypt_all_encrypted.py" %*
if errorlevel 1 (
  echo.
  echo Algunos archivos fallaron. Ver scripts_encrypted_extracted\MANIFEST.txt
)
echo.
echo Opcional: anade --ramdisks para volver a extraer ramdisks\*.zip.enc
echo Salida scripts: %~dp0scripts_encrypted_extracted
pause
