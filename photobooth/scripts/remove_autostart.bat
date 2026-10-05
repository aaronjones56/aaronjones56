@echo off
rem Supprime le lancement automatique du photobooth.
setlocal EnableExtensions
set "PB_LINK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Photobooth.lnk"
if exist "%PB_LINK%" (
  del "%PB_LINK%"
  echo Lancement automatique supprime.
) else (
  echo Aucun lancement automatique n'etait configure.
)
pause
