# Fabrique PanadapterBridge-<version>.zip à partir des fichiers du dossier.
# La version est lue dans PanadapterBridge.ps1 ($Version = '...').
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$m = Select-String -Path "$root\PanadapterBridge.ps1" -Pattern "^\`$Version = '([^']+)'" | Select-Object -First 1
if (-not $m) { throw 'Version introuvable dans PanadapterBridge.ps1' }
$ver = $m.Matches[0].Groups[1].Value
$zip = "$root\PanadapterBridge-$ver.zip"
if (Test-Path $zip) { Remove-Item $zip }
$files = 'PanadapterBridge.bat', 'PanadapterBridge_debug.bat', 'PanadapterBridge.ps1', 'LISEZMOI.txt' | ForEach-Object { "$root\$_" }
Compress-Archive -Path $files -DestinationPath $zip
Write-Host "Créé : $zip"
