# Notes de développement — PanadapterBridge

Pour reprendre le projet lors d'une prochaine session.

## Où est quoi
- Dépôt / sauvegarde : `j:\claude\PanadapterBridge` (GitHub : F5pbgLudovic/PanadapterBridge, public).
- Version de travail utilisée sur la station : `C:\FT2000 expertsdr - PanadapterBridge\` (raccourci Bureau « Panadapter Bridge »). Elle contient en plus `PanadapterBridge.json` (réglages personnels) et `logs\`, qui ne sont jamais versionnés.
- Programme : un seul script PowerShell + WinForms, `PanadapterBridge.ps1` (UTF-8 avec BOM, à conserver). Version dans `$Version` ; le titre de la fenêtre l'affiche.

## Faire évoluer
1. Modifier le script (de préférence sur une copie, voir « Tests »), puis le recopier dans les deux dossiers.
2. Changer `$Version`, mettre à jour `LISEZMOI.txt` et `README.md`.
3. `powershell -ExecutionPolicy Bypass -File build.ps1` produit `PanadapterBridge-<version>.zip`.
4. Commit, puis push et release (seulement sur demande de l'utilisateur) :
   - PATH : ajouter `C:\Program Files\Git\cmd` et `C:\Program Files\GitHub CLI`
   - `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin main`
   - `gh release create vX.Y PanadapterBridge-X.Y.zip --repo F5pbgLudovic/PanadapterBridge --title "PanadapterBridge VX.Y" --notes-file release-notes.md --latest`
   - re-télécharger le zip avec `gh release download` et comparer les empreintes.
   - Notes de release : même format que 1.0 (Télécharger, Fonctions, Nouveautés, résumé English, « 73 de F5PBG »). Le fichier `release-notes.md` est local (ignoré par git).

## Tests
Ne jamais tester sur la station en direct (ExpertSDR3, HRD, FT-2000). Utiliser une copie isolée avec son propre `.json`, et des faux serveurs sur des ports vérifiés libres. Ne jamais envoyer de commande à un processus réel.

## Points ouverts
- La notice dit « port TCI 50001 » alors que le réglage de la station est 40001 : à harmoniser.
- Le mode ne se synchronise que dans le sens FT-2000 → ExpertSDR3 (limite du serveur IP de HRD).
