<p align="center">
  <img src="assets/AppIcon.png" width="128" height="128" alt="Icône de Diktation">
</p>

<h1 align="center">Diktation</h1>

<p align="center">
  <b>Parlez naturellement, Diktation écrit.</b><br>
  Dictée vocale privée et hors ligne pour macOS. Maintenez une touche, parlez, relâchez : le texte apparaît là où est votre curseur.
</p>

<p align="center">
  <a href="https://github.com/Senooy/Diktation/releases/latest"><b>Télécharger pour Mac</b></a> ·
  <a href="README.md">Read in English</a>
</p>

<p align="center">
  <img src="assets/screenshots/welcome-fr.png" width="746" alt="Accueil de Diktation">
</p>

---

Diktation est une alternative libre et gratuite aux apps de dictée par abonnement. La reconnaissance vocale tourne **entièrement sur votre Mac** avec [whisper.cpp](https://github.com/ggml-org/whisper.cpp), sur le GPU (Metal). Pas de compte, pas de cloud, pas d'abonnement, pas de télémétrie. Votre voix et vos textes ne quittent jamais la machine.

## Fonctions

- **Maintenir pour dicter, partout.** Maintenez <kbd>fn</kbd> dans n'importe quelle app, parlez, relâchez : le texte est collé au curseur. Une phrase revient en bien moins d'une seconde sur puce Apple.
- **Mains libres.** Deux appuis rapides sur <kbd>fn</kbd> pour écouter sans tenir la touche ; un nouvel appui termine. <kbd>esc</kbd> annule.
- **Texte propre.** Ponctuation et majuscules par le modèle, hésitations (« euh », « heu ») retirées, commandes vocales « à la ligne » et « nouveau paragraphe ».
- **Style selon l'app** *(Apple Intelligence, sur le Mac)*. Emails soignés, messagerie pro neutre, messages perso décontractés. Un ton par catégorie, ou la dictée brute.
- **Mode commande** *(Apple Intelligence, sur le Mac)*. Sélectionnez du texte, maintenez <kbd>fn</kbd> + <kbd>⌃</kbd> et dites quoi en faire : « rends ça plus poli », « traduis en anglais », « fais-en une liste ». Sans sélection, Diktation rédige ce que vous demandez.
- **Dictionnaire personnel.** Noms propres, marques et jargon sont soufflés au modèle avant chaque dictée, plus des corrections automatiques pour les mots qu'il écorche toujours.
- **Raccourcis vocaux.** Dites « mon adresse mail » et Diktation la tape. Pareil pour une signature, un lien, une réponse type.
- **Mode réunion.** Un espace dédié avec enregistrement en présentiel (micro) ou en visio (micro + son du Mac), transcription progressive, intervenants identifiés à la fin et notes personnelles côte à côte. Renommez les intervenants et exportez transcription + notes en Markdown. [Utilisation et limites](docs/mode-reunion.md).
- **Intervenants et horodatages.** Analyse locale à la demande depuis l’historique : détection des voix, nombre automatique ou imposé, copie du texte par intervenant. Deux modèles supplémentaires (~47 Mo), disponibles dans les réglages. Les numéros sont propres à chaque enregistrement.
- **Décodage Whisper rapide.** Option de latence réduite dans les réglages, avec un compromis possible sur la précision.
- **Historique.** Chaque dictée reste sur le Mac, avec recherche et audio pour re-transcrire. Suppression automatique après 24 h en option. <kbd>⌃</kbd><kbd>⌘</kbd><kbd>V</kbd> recolle la dernière.
- **Une petite pastille flottante** montre l'app où vous dictez et la forme d'onde en direct, puis s'efface.
- **Interface en français ou en anglais**, selon la langue du Mac. La dictée fonctionne dans de nombreuses langues (français, anglais, espagnol, allemand, italien, arabe, détection auto…).

## Configuration requise

- Un Mac à **puce Apple** (M1 ou plus récent).
- **macOS 14 Sonoma** ou plus récent. Le style selon l'app et le mode commande demandent **macOS 26** avec Apple Intelligence activé ; tout le reste fonctionne sans.
- Environ **1,7 Go** d'espace libre pour le modèle recommandé (un modèle compact de 574 Mo est aussi proposé).

## Installation

1. Téléchargez `Diktation-<version>.dmg` depuis la [dernière version](https://github.com/Senooy/Diktation/releases/latest).
2. Ouvrez-le et glissez **Diktation** dans **Applications**. L'app est signée et notarisée par Apple.
3. Lancez-la. L'accueil vous guide pas à pas :
   - téléchargement du modèle de transcription (avec progression, reprise possible),
   - autorisation du **micro**,
   - autorisation **Accessibilité** (raccourci global et collage dans les autres apps),
   - vérification du raccourci, puis première dictée.

> **Astuce :** si l'appui sur <kbd>fn</kbd> ouvre aussi les emojis ou la dictée d'Apple, réglez **Réglages Système → Clavier → « Touche 🌐 » → « Ne rien faire »**, ou choisissez un autre raccourci dans les réglages de Diktation (toute combinaison de modificateurs, par exemple <kbd>⌥</kbd> droite).

## Utilisation

| Geste | Effet |
|---|---|
| Maintenir <kbd>fn</kbd> | Écoute ; relâcher pour transcrire et coller |
| Deux appuis sur <kbd>fn</kbd> | Mains libres ; un appui pour terminer |
| <kbd>esc</kbd> pendant l'écoute | Annuler |
| Maintenir <kbd>fn</kbd> + <kbd>⌃</kbd> | Mode commande sur le texte sélectionné |
| <kbd>⌃</kbd> <kbd>⌘</kbd> <kbd>V</kbd> | Recoller la dernière dictée |
| Dire « à la ligne » / « nouveau paragraphe » | Saut de ligne ou de paragraphe |

L'icône de la barre des menus donne accès à la fenêtre, à la dernière dictée et à Quitter. Fermer la fenêtre range Diktation dans la barre des menus : l'app quitte le Dock et le raccourci reste actif. On la rouvre depuis l'icône de la barre des menus ou en relançant l'app.

## Confidentialité

- Le micro reste actif pendant la dictée puis jusqu’à 10 secondes pour faciliter l’enchaînement. Une pré-écoute de 300 ms est gardée en mémoire pendant cette période ; le flux repasse ensuite en pause.
- La transcription tourne en local avec whisper.cpp. Le style et le mode commande utilisent le modèle d'Apple sur l'appareil (framework FoundationModels).
- Le réseau sert aux vérifications et téléchargements des mises à jour via GitHub Releases ainsi qu’au téléchargement des modèles : [whisper.cpp sur Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) et [versions officielles de sherpa-onnx sur GitHub](https://github.com/k2-fsa/sherpa-onnx/releases). La transcription et l’analyse des intervenants restent locales.
- Historique, audio et réglages sont dans `~/Library/Application Support/Diktation`. Supprimez ce dossier pour tout effacer.

## Modèles

On choisit et télécharge les modèles dans **Réglages → Modèle de transcription** (ou à l'accueil). Deux moteurs cohabitent : [whisper.cpp](https://github.com/ggml-org/whisper.cpp) sur le GPU, et [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (ONNX Runtime) pour les modèles plus récents. Temps mesurés sur une phrase de 7 secondes, sur M5 Pro, modèle chargé.

| Modèle | Téléchargement | Langues | Vitesse | Remarques |
|---|---|---|---|---|
| Whisper Turbo (`large-v3-turbo`) | 1,6 Go | ~100 | ~0,7–1,1 s | Choix par défaut ; suit le dictionnaire |
| NVIDIA Parakeet TDT v3 | 487 Mo | 25 européennes | ~0,3 s | Très rapide, excellent en français et en anglais |
| NVIDIA Nemotron 3.5 ASR (juin 2026) | 475 Mo | Multilingue | ~1,3 s | Le plus récent de NVIDIA, langue imposée ou détectée |
| Qwen3-ASR 0.6B (mars 2026) | 879 Mo | 52 | ~1,3 s | Modèle multilingue récent |
| Cohere Transcribe (avril 2026) | 1,7 Go | 14 | ~2 s | Le plus précis des modèles récents |
| NVIDIA Canary 180M flash | 154 Mo | fr, en, es, de | ~0,5 s | Ultra léger ; bien régler la langue de dictée (sinon il traduit) |
| NVIDIA Parakeet Unified | 501 Mo | Anglais | ~0,3 s | Dernier Parakeet anglais |
| Moonshine base | 111 Mo | Anglais | ~0,1 s | Quasi instantané |
| Whisper Turbo compact, Large v3, Small | 0,5–3,1 Go | ~100 | | Autres tailles de whisper.cpp |

Seul Whisper lit le dictionnaire personnel avant de transcrire ; les corrections automatiques et les raccourcis vocaux marchent avec tous les modèles. Chaque modèle garde sa propre licence (voir sa page sur Hugging Face ou dans les versions de sherpa-onnx). Les modèles sont rangés dans `~/Library/Application Support/Diktation/models` (les fichiers whisper de `~/.cache/whisper` sont aussi repris).

Les nouveaux réglages, les limites de l’analyse des intervenants et les mesures de latence sont détaillés dans [la note de validation](docs/transcription-et-intervenants.md).

## Compiler soi-même

Il faut les outils en ligne de commande de Xcode, Rust (via [rustup](https://rustup.rs)) et CMake.

```sh
git clone https://github.com/Senooy/Diktation.git
cd Diktation
./bundle.sh          # compile le cœur Rust et l'app SwiftUI, puis signe Diktation.app
open Diktation.app
```

À partir de 1.2.0, les mises à jour sont vérifiées automatiquement et téléchargées en arrière-plan via Sparkle. Les options sont dans Réglages → Mises à jour. Les versions antérieures nécessitent une dernière installation manuelle. Voir le [guide de distribution](docs/mises-a-jour.md) pour la signature, la notarisation et GitHub Actions.

`./release.sh` produit un DMG notarisé (certificat Developer ID et profil `notarytool` requis, voir l'en-tête du script). L'architecture est décrite dans le [README anglais](README.md#how-it-works).

## Licence

[MIT](LICENSE) © 2026 Younes Khelifi
