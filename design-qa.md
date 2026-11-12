# Vérification visuelle — Diktation

Date : 12 novembre 2026. Périmètre : adaptation de la direction artistique de Hey Pongo à l’application macOS existante, avec accès direct aux deux usages et conservation du mode réunion. Il ne s’agit pas de reproduire la mise en page du site marketing.

## Preuves

- Référence : https://www.heypongo.com/, capture `target/validation/pongo-reference.png` (1280 × 720, navigateur intégré).
- Accueil : `target/validation/design-home.png` (fenêtre 1120 × 760 points, capture Retina 2240 × 1520).
- Comparaison réunie : `target/validation/design-comparison.png`, images ajustées proportionnellement à deux colonnes de même largeur ; comparaison de palette, grain et hiérarchie, sans comparaison pixel à pixel de dispositions différentes.
- Contrôles rapprochés sur les captures natives : accueil à 940 × 680, réunion à 1080 × 680, lancement à 940 × 680, essai et réglages. Les fichiers `design-home-narrow[-en].png`, `design-meeting-draft-narrow[-en].png`, `design-meeting-ready-narrow.png`, `design-onboarding-narrow.png`, `design-practice.png` et `design-settings.png` se trouvent dans `target/validation/`.
- Les données de réunion des aperçus sont fictives. Les captures sont produites par NSHostingView avec les composants de production, ressources intégrées au bundle, et état isolé.

## Résultat par surface

- Typographie : Manrope réellement chargée (`Manrope-Regular` confirmé), graisses fortes pour les titres, petits textes lisibles. Svatopluk n’est pas redistribuée. Français et anglais contrôlés aux tailles étroites.
- Espacement : actions de l’accueil visibles à la taille minimale ; navigation, sources de réunion et export accessibles. Les zones de notes et transcription défilent séparément.
- Couleurs : crème `#FFFDF5`, prune `#25041D`, accent mûre, lilas. Texte secondaire plus sombre ; états désactivés distincts. Fond grainé réservé aux zones d’accueil et d’essai pour garder la lecture des échanges sobre.
- Images : texture originale embarquée, sans réseau au lancement. Icônes SF Symbols ; aucune photographie ou marque Pongo copiée.
- Contenu : deux intentions explicites, essai de dictée, préparation de réunion sans démarrage automatique du micro, accès aux réglages lorsque les modèles manquent. Messages FR/EN présents.

## Vérifications fonctionnelles et limites

Compilation Swift et bundle réussis ; signature de l’application installée vérifiée ; ressources présentes et identiques au dépôt. Ouverture de l’essai depuis le nouvel accueil testée dans l’application installée, avec focus sur le champ de texte et message d’autorisation approprié. L’état final observé indique « Tout est prêt ». Les interactions de saisie supplémentaires ont été interrompues lorsque l’utilisateur a repris la fenêtre ; elles ne sont pas revendiquées comme testées. Aucun nouveau test matériel de dictée ou de capture de réunion n’a été effectué pour cette refonte visuelle.

Comparaison finale : aucun problème visuel P0/P1/P2 identifié. La densité est adaptée à une application native, avec une texture plus légère que la grande section marketing de référence. Raffinement P3 possible : aligner les séparateurs de colonnes lorsque leurs textes d’aide occupent des hauteurs différentes.

final result: passed
