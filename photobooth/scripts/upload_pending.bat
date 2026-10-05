@echo off
rem Envoie vers le site toutes les photos en attente (tous les evenements).
rem A lancer apres l'evenement, une fois la borne connectee a Internet.
setlocal EnableExtensions
title Photobooth - upload des photos
cd /d "%~dp0.."

if not exist "venv\Scripts\python.exe" (
  echo [ERREUR] Environnement Python introuvable : lancez d'abord scripts\install.bat
  pause
  exit /b 1
)

echo Envoi des photos en attente...
echo.
"venv\Scripts\python.exe" manage.py upload --all
if errorlevel 1 (
  echo.
  echo Certaines photos n'ont pas ete envoyees : elles restent en attente.
  echo Relancez ce script plus tard ou utilisez le bouton Upload de l'administration.
)
echo.
pause
