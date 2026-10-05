@echo off
rem Lance le photobooth en mode kiosk :
rem   1. demarre le serveur (fenetre reduite, redemarrage automatique) ;
rem   2. attend qu'il reponde ;
rem   3. ouvre Chrome ou Edge en plein ecran (mode kiosk).
rem Pour quitter : Ctrl+Alt+Q (code PIN), ou 5 touches dans le coin en haut a gauche, ou Alt+F4.
setlocal EnableExtensions
title Photobooth - lancement
cd /d "%~dp0.."
set "ROOT=%CD%"

rem Navigateur : auto (Chrome s'il est installe, sinon Edge), chrome ou edge
set "KIOSK_BROWSER=auto"

set "PORT=5000"
if exist ".env" (
  for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /i "PORT=" ".env"`) do set "PORT=%%B"
)
if not defined PORT set "PORT=5000"
set "URL=http://127.0.0.1:%PORT%"
set "PROFILE_DIR=%LOCALAPPDATA%\PhotoboothKioskProfile"

if not exist "venv\Scripts\python.exe" (
  echo [ERREUR] Environnement Python introuvable : lancez d'abord scripts\install.bat
  pause
  exit /b 1
)

rem 1. Serveur (sauf s'il tourne deja)
curl.exe -s -f -o nul --max-time 2 "%URL%/api/health"
if errorlevel 1 (
  echo Demarrage du serveur...
  start "Photobooth Server" /min cmd /c ""%ROOT%\scripts\run_server.bat""
)

rem 2. Attente du serveur (60 secondes maximum)
set /a TRIES=0
:wait_server
curl.exe -s -f -o nul --max-time 2 "%URL%/api/health"
if not errorlevel 1 goto :server_ready
set /a TRIES+=1
if %TRIES% GEQ 60 goto :server_failed
timeout /t 1 /nobreak >nul
goto :wait_server

:server_failed
echo [ERREUR] Le serveur ne repond pas sur %URL%. Consultez logs\photobooth.log
pause
exit /b 1

:server_ready
rem 3. Navigateur en plein ecran
set "BROWSER="
set "CHROME="
set "EDGE="
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" set "CHROME=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not defined EDGE if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"

if /i "%KIOSK_BROWSER%"=="chrome" set "BROWSER=%CHROME%"
if /i "%KIOSK_BROWSER%"=="edge" set "BROWSER=%EDGE%"
if /i "%KIOSK_BROWSER%"=="auto" (
  if defined CHROME (set "BROWSER=%CHROME%") else (set "BROWSER=%EDGE%")
)
if not defined BROWSER (
  echo [ATTENTION] Ni Chrome ni Edge trouve : ouverture avec le navigateur par defaut.
  start "" "%URL%"
  exit /b 0
)

echo Ouverture du photobooth en plein ecran...
start "" "%BROWSER%" --kiosk "%URL%" --edge-kiosk-type=fullscreen --user-data-dir="%PROFILE_DIR%" ^
  --no-first-run --no-default-browser-check --disable-pinch --overscroll-history-navigation=0 ^
  --disable-features=Translate,TranslateUI --hide-crash-restore-bubble --disable-session-crashed-bubble ^
  --noerrdialogs --disable-infobars --autoplay-policy=no-user-gesture-required --check-for-update-interval=31536000
exit /b 0
