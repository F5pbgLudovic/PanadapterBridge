# PanadapterBridge 1.0 — @F5PBG 2026

*[English version below](#english)*

PanadapterBridge relie **ExpertSDR3** (ColibriNANO branché sur la 1ère FI du **Yaesu FT-2000**, 69,450 MHz nominal) au **FT-2000** : un clic dans le panorama d'ExpertSDR3 fait faire un QSY au poste, et ExpertSDR3 est ramené sur la FI, le signal cliqué au centre.

## Fonctions

- **Clic dans le panorama** : le FT-2000 passe sur la fréquence cliquée (inversion de la FI prise en compte, arrondi au pas choisi, 500 Hz par défaut).
- **Molette** : un cran déplace le poste d'un pas fixe (100 à 500 Hz, réglable) en restant sur la grille.
- **ExpertSDR3 maintenu sur la FI** (VFO et centre du panorama).
- **Mode recopié** du FT-2000 vers ExpertSDR3 (LSB/USB échangés), avec la FI propre à chaque mode (LSB, USB, CW, AM, FM, DIG).
- **Liaison au poste** par Ham Radio Deluxe (serveur IP, port 7809) ou en CAT direct sur un port COM.
- Scan, historique de fréquences, voyants de connexion, journal, démarrage avec Windows, fenêtre au premier plan.

## Télécharger

**[Télécharger la dernière version](https://github.com/F5pbgLudovic/PanadapterBridge/releases/latest)** (`PanadapterBridge-1.0.zip`). Décompressez, puis double-cliquez sur `PanadapterBridge.bat`.

Rien à installer : PowerShell et WinForms sont intégrés à Windows 10 et 11.

## Mise en route

1. Dans ExpertSDR3 : Options → TCI → activer, noter le port (réglable dans PanadapterBridge).
2. Dans HRD Rig Control : Tools → IP Server → cocher « Enable », port 7809.
3. Lancer `PanadapterBridge.bat`, vérifier les FI par mode, puis **Démarrer**.
4. Cliquer sur un signal dans ExpertSDR3 : le FT-2000 doit suivre.

La notice complète est dans [LISEZMOI.txt](LISEZMOI.txt).

## Sécurité

Le `.bat` lance PowerShell avec `-ExecutionPolicy Bypass` uniquement pour ce script : aucun réglage de Windows n'est modifié. Le programme est un script en clair ([PanadapterBridge.ps1](PanadapterBridge.ps1)), donc relisible. Un antivirus peut demander une confirmation au premier lancement.

## Licence

[MIT](LICENSE)

---

## English

**PanadapterBridge** links **ExpertSDR3** (a ColibriNANO connected to the 1st IF of a **Yaesu FT-2000**, 69.450 MHz nominal) with the **FT-2000**: a click in the ExpertSDR3 panadapter QSYs the rig, then ExpertSDR3 is brought back to the IF with the clicked signal at the centre.

### Features

- **Click in the panadapter**: the FT-2000 tunes to the clicked frequency (IF inversion handled, rounded to the chosen step, 500 Hz by default).
- **Mouse wheel**: one notch moves the rig by a fixed step (100 to 500 Hz, adjustable), staying on the grid.
- **ExpertSDR3 kept on the IF** (VFO and panadapter centre).
- **Mode copied** from the FT-2000 to ExpertSDR3 (LSB/USB swapped), using the IF specific to each mode (LSB, USB, CW, AM, FM, DIG).
- **Rig link** through Ham Radio Deluxe (IP server, port 7809) or direct CAT on a COM port.
- Scan, frequency history, connection lamps, log, start with Windows, always-on-top window.

### Download

**[Download the latest release](https://github.com/F5pbgLudovic/PanadapterBridge/releases/latest)** (`PanadapterBridge-1.0.zip`). Unzip, then double-click `PanadapterBridge.bat`. Nothing to install: PowerShell and WinForms are built into Windows 10 and 11.

### Quick start

1. ExpertSDR3: Options → TCI → enable, note the port (configurable in PanadapterBridge).
2. HRD Rig Control: Tools → IP Server → tick "Enable", port 7809.
3. Run `PanadapterBridge.bat`, check the IFs per mode, then press **Start** (Démarrer).
4. Click a signal in ExpertSDR3: the FT-2000 should follow.

The full manual (in French) is in [LISEZMOI.txt](LISEZMOI.txt).

### Security

The `.bat` starts PowerShell with `-ExecutionPolicy Bypass` for this script only; no Windows setting is changed. The program is a plain-text script ([PanadapterBridge.ps1](PanadapterBridge.ps1)), so it can be read. An antivirus may ask for confirmation on first run.

### Licence

[MIT](LICENSE)

73 de F5PBG
