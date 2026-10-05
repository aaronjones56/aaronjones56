@echo off
rem Installation du photobooth : environnement Python, dependances, fichier .env.
setlocal EnableExtensions
title Photobooth - installation
cd /d "%~dp0.."

echo ============================================================
echo   Installation du photobooth
echo ============================================================
echo.

set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY where python >nul 2>nul && set "PY=python"
if not defined PY (
  echo [ERREUR] Python est introuvable.
  echo Installez Python 3.12 ou plus recent depuis https://www.python.org/downloads/
  echo en cochant "Add python.exe to PATH", puis relancez ce script.
  pause
  exit /b 1
)

%PY% -c "import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)"
if errorlevel 1 (
  echo [ERREUR] Python 3.12 ou plus recent est necessaire. Version detectee :
  %PY% --version
  pause
  exit /b 1
)

if not exist "venv\Scripts\python.exe" (
  echo Creation de l'environnement virtuel venv...
  %PY% -m venv venv
  if errorlevel 1 goto :error
)

echo Installation des dependances, cela peut prendre quelques minutes...
"venv\Scripts\python.exe" -m pip install --upgrade pip
if errorlevel 1 goto :error
"venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto :error

if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Fichier .env cree a partir de .env.example : pensez a changer ADMIN_PIN.
)

echo.
echo Verification des images d'exemple et du materiel...
"venv\Scripts\python.exe" manage.py generate-assets
"venv\Scripts\python.exe" manage.py check

echo.
echo ============================================================
echo   Installation terminee
echo ============================================================
echo   Tester        : venv\Scripts\python.exe app.py   puis http://127.0.0.1:5000
echo   Mode kiosk    : scripts\start_kiosk.bat
echo   Administration: http://127.0.0.1:5000/admin
echo.
pause
exit /b 0

:error
echo.
echo [ERREUR] L'installation a echoue : lisez les messages ci-dessus.
pause
exit /b 1
