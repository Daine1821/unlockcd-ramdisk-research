@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo UnlockCD ramdisk decrypt + extract
echo.

where py >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python launcher "py" not found. Install Python 3 from python.org.
  exit /b 1
)

py -3 "%~dp0decrypt_all_ramdisks.py"
set ERR=%ERRORLEVEL%

echo.
if %ERR% neq 0 (
  echo Finished with errors. Exit code: %ERR%
) else (
  echo Done. Output folder: "%~dp0ramdisks_extracted"
)
pause
exit /b %ERR%
