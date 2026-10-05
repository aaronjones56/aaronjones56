@echo off
rem Ferme le navigateur kiosk et arrete le serveur du photobooth.
setlocal EnableExtensions
title Photobooth - arret
echo Fermeture du navigateur kiosk...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*PhotoboothKioskProfile*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
echo Arret du serveur...
taskkill /FI "WINDOWTITLE eq Photobooth Server*" /T /F >nul 2>nul
echo Photobooth arrete.
timeout /t 2 /nobreak >nul
