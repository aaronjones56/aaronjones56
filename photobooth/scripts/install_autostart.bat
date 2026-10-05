@echo off
rem Lance automatiquement le photobooth a l'ouverture de la session Windows
rem (raccourci vers start_kiosk.bat dans le dossier Demarrage).
setlocal EnableExtensions
cd /d "%~dp0.."
set "PB_TARGET=%CD%\scripts\start_kiosk.bat"
set "PB_WORKDIR=%CD%"
set "PB_LINK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Photobooth.lnk"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:PB_LINK); $s.TargetPath = $env:PB_TARGET; $s.WorkingDirectory = $env:PB_WORKDIR; $s.WindowStyle = 7; $s.Description = 'Photobooth (mode kiosk)'; $s.Save()"
if errorlevel 1 (
  echo [ERREUR] Impossible de creer le raccourci de demarrage.
) else (
  echo Le photobooth demarrera automatiquement a l'ouverture de session.
  echo Raccourci : %PB_LINK%
  echo Pour annuler : scripts\remove_autostart.bat
)
pause
