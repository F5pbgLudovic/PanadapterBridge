@echo off
rem Meme chose mais avec la console visible : a utiliser si la fenetre ne s'ouvre pas, pour lire le message d'erreur.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PanadapterBridge.ps1"
pause
