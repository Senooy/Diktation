# Mode réunion

## Parcours

1. Ouvrir **Réunions → Nouvelle réunion**.
2. Donner un titre et préparer ses notes dans **Mes notes**.
3. Choisir **Présentiel · micro** ou **Visio · micro + son du Mac**, vérifier le micro et, éventuellement, choisir le nombre d’intervenants connu (sinon automatique).
4. Cliquer **Enregistrer**. Le texte provisoire apparaît à gauche par passages de 5 secondes, plus le temps d’inférence. Les notes restent libres et sauvegardées à chaque modification.
5. Cliquer **Terminer**. L’enregistrement est sauvegardé, puis le modèle analyse les intervenants sur toute sa durée et remplace le texte provisoire par une transcription finale horodatée.
6. Nommer les intervenants si souhaité. **Copier** ou **Exporter .md** rassemble le titre, la date, les prises de parole et les notes personnelles.

Les modèles de transcription et d’intervenants doivent être installés avant le démarrage. Ils se trouvent dans les réglages. Le mode utilise le microphone sélectionné dans Diktation. En visio, il ajoute le son des autres applications du Mac, dont Zoom, Meet ou Teams. Durée maximale d’une session : 60 minutes.

## Son des visioconférences

Au premier démarrage en mode visio, macOS demande les autorisations microphone et enregistrement de l’écran/son système. Les autorisations se règlent dans **Réglages Système → Confidentialité et sécurité**. Aucune vidéo n’est conservée. La capture inclut les autres applications du Mac, pas uniquement l’application de réunion.

Utiliser un casque : il n’y a pas de suppression d’écho intégrée et les haut-parleurs peuvent réinjecter les participants distants dans le microphone. Deux indicateurs **Micro** et **Mac** affichent les niveaux reçus pendant l’enregistrement.

Les sources sont converties séparément en mono 16 kHz, alignées sur l’horloge système, puis mélangées avec une marge pour limiter la saturation. La transcription provisoire attend une demi-seconde supplémentaire pour laisser arriver les paquets des deux sources. La source choisie est conservée dans la réunion. Un refus d’autorisation empêche le démarrage ; une erreur de capture interrompt la réunion avec un message visible et lance le traitement de l’audio déjà reçu.

## Comportement

- La transcription reste dans la réunion : aucun collage automatique dans l’app active.
- La dictée au raccourci est suspendue pendant l’enregistrement et son traitement final, pour ne pas interrompre la prise de notes ou partager le micro.
- Les notes, le titre et les noms d’intervenants sont indépendants du résultat des modèles. Une transcription terminée ne les remplace jamais.
- Le texte pendant l’écoute est **provisoire**, sans identité d’intervenant. La numérotation finale est calculée sur l’ensemble de l’enregistrement pour éviter des numéros incohérents d’un passage à l’autre.
- La transcription finale utilise le mode de précision normal, même si le décodage Whisper rapide est activé pour la dictée.
- Le mode ne reformule pas les échanges avec Apple Intelligence et n’interprète pas les raccourcis ou commandes vocales : il conserve la transcription des paroles.
- La réouverture d’une réunion permet de relire les échanges et de continuer ses notes. **Re-transcrire** relance l’analyse avec le modèle de transcription actuellement sélectionné, la langue et le nombre d’intervenants d’origine.
- Quitter normalement l’application termine et sauvegarde une réunion en cours, puis attend son traitement. Fermer simplement la fenêtre laisse l’enregistrement actif dans l’application.

## Sauvegarde et récupération

Les réunions utilisent `~/Library/Application Support/Diktation/meetings.sqlite` et un dossier audio dédié `meetings/<id>/`. Elles conservent leur audio même si « Garder l’audio » est désactivé pour les dictées. L’effacement ou la suppression automatique de l’historique des dictées ne touche pas les réunions. Leur bouton de suppression efface leurs notes, leur transcription et leur audio.

Chaque passage traité produit un WAV intermédiaire écrit dans un fichier temporaire, puis installé par renommage. À l’arrêt, le WAV complet est sauvegardé avant l’analyse finale. Après une interruption, les notes et passages déjà sauvegardés restent accessibles ; **Re-transcrire** utilise le WAV complet ou, à défaut, les fichiers intermédiaires contigus. Un intervalle manquant déclenche une erreur plutôt que de décaler les horodatages. La partie encore en mémoire au moment d’un arrêt forcé peut être perdue.

## Validation du 12 novembre 2026

- 27 tests unitaires Rust réussis, dont conservation des notes pendant la mise à jour de la transcription, récupération des sessions interrompues, protection contre les résultats tardifs et continuité des fichiers audio intermédiaires, mélange horodaté des deux sources et rejet des paquets invalides.
- Un test d’intégration supplémentaire avec les vrais modèles Parakeet et Pyannote/TitaNet : sauvegarde d’un WAV, analyse de deux voix et quatre prises de parole, modification des notes pendant le traitement, puis réouverture de la base. Les notes, noms, titre et transcription sont conservés. Le même extrait est ensuite transmis via deux pistes horodatées au contrôleur de réunion visio ; les deux voix et quatre prises de parole restent identifiées.
- Tests de conversion Swift à 16 / 44,1 / 48 kHz, en mono et stéréo, avec vérification du nombre de samples et de l’amplitude, y compris un véritable `CMSampleBuffer`.
- Vérification Swift, compilation de l’application et contrôle du rendu natif des deux colonnes avec des données fictives.
- Le parcours matériel complet (autorisations macOS, micro, son d’une vraie visioconférence, arrêt) et une session d’une heure n’ont pas encore été validés manuellement. La précision sur les voix simultanées et les réunions longues reste à mesurer ; les segments superposés sont signalés et peuvent contenir des erreurs d’attribution.

```sh
cargo test --lib
DIKTATION_MEETING_FIXTURE="$PWD/target/validation/models/1-two-speakers-en.wav" \
  cargo test --release meetings::tests::real_meeting_pipeline_preserves_notes -- --ignored
DIKTATION_SIGN_IDENTITY=- ./bundle.sh
```

Le test d’intégration utilise une base et un dossier audio temporaires, sans modifier les réunions de l’utilisateur. L’extrait public est fourni dans les [modèles de segmentation officiels sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models). Les artefacts de validation se trouvent dans `target/validation/meeting-*` et `target/validation/capture-*` et ne sont pas versionnés.
