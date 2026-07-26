@echo off
setlocal
set "APP=%~dp0UnlockCD-Ramdisk-V1.0.app\Contents\Resources"
set "OUT=%~dp0mount_mnt2_extracted"
set "WIN=%~dp0UnlockCD-Windows"
if not exist "%APP%\tools\remote_mount_dynamic.sh" (
  echo ERROR: no encuentro %APP%\tools\remote_mount_dynamic.sh
  pause & exit /b 1
)
mkdir "%OUT%\scripts" 2>nul
mkdir "%OUT%\plists" 2>nul
mkdir "%OUT%\restore_work_ejemplo" 2>nul
mkdir "%OUT%\windows_helpers" 2>nul
copy /Y "%APP%\tools\remote_mount_dynamic.sh" "%OUT%\scripts\" >nul
copy /Y "%APP%\tools\remote_mount_old.sh" "%OUT%\scripts\" >nul
copy /Y "%APP%\tools\backup_activation_simple.sh" "%OUT%\scripts\" >nul
copy /Y "%APP%\backup_activation.sh" "%OUT%\scripts\" >nul
copy /Y "%APP%\tools\disabled.plist" "%OUT%\plists\" >nul
if exist "%APP%\restore_work\20260725_134432\restore.log" (
  copy /Y "%APP%\restore_work\20260725_134432\restore.log" "%OUT%\restore_work_ejemplo\" >nul
  copy /Y "%APP%\restore_work\20260725_134432\summary.txt" "%OUT%\restore_work_ejemplo\" >nul
)
if exist "%WIN%\scripts\restore_tickets_remote.sh" copy /Y "%WIN%\scripts\restore_tickets_remote.sh" "%OUT%\scripts\" >nul
if exist "%WIN%\scripts\restore_from_zip.sh" copy /Y "%WIN%\scripts\restore_from_zip.sh" "%OUT%\scripts\" >nul
if exist "%~dp0scripts_encrypted_extracted\start.sh" (
  mkdir "%OUT%\decrypted_from_enc" 2>nul
  copy /Y "%~dp0scripts_encrypted_extracted\*.sh" "%OUT%\decrypted_from_enc\" >nul 2>nul
  copy /Y "%~dp0scripts_encrypted_extracted\mnt2.macho" "%OUT%\decrypted_from_enc\" >nul 2>nul
)
for %%F in (4_MOUNT 5_MOUNT_CON_USER 6_BACKUP_ACTIVACION_SIMPLE 7_BACKUP_ACTIVACION_COMPLETO 8_RESTORE_TICKETS) do (
  if exist "%WIN%\%%F.bat" copy /Y "%WIN%\%%F.bat" "%OUT%\windows_helpers\" >nul
)
echo OK -> %OUT%
echo Ver MANIFEST.txt
pause
