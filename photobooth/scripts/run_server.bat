@echo off
rem Serveur du photobooth avec redemarrage automatique :
rem   - code 3 : redemarrage demande depuis l'administration ;
rem   - autre code : arret inattendu, relance apres 5 secondes ;
rem   - code 0 : arret normal (Quitter le kiosk), la fenetre se ferme.
setlocal EnableExtensions
title Photobooth Server
cd /d "%~dp0.."

if not exist "venv\Scripts\python.exe" (
  echo [ERREUR] Environnement Python introuvable : lancez d'abord scripts\install.bat
  pause
  exit /b 1
)

set "PHOTOBOOTH_SUPERVISED=1"
set /a CRASHES=0

:loop
"venv\Scripts\python.exe" app.py
set "EXITCODE=%ERRORLEVEL%"
if "%EXITCODE%"=="0" goto :end
if "%EXITCODE%"=="3" (
  echo Redemarrage demande depuis l'administration...
  set /a CRASHES=0
  goto :loop
)
set /a CRASHES+=1
if %CRASHES% GEQ 20 goto :too_many
echo Le serveur s'est arrete de facon inattendue (code %EXITCODE%). Relance dans 5 secondes...
timeout /t 5 /nobreak >nul
goto :loop

:too_many
echo [ERREUR] Trop d'arrets successifs : consultez logs\photobooth.log
pause

:end
endlocal
