@echo off
rem PanadapterBridge - lance l'utilitaire (fenetre) sans console. Windows 10 / 11, rien a installer.
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0PanadapterBridge.ps1"
