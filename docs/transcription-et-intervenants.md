# Transcription, latence et intervenants

Validation locale du 12 novembre 2026, Apple M5 Pro. **20 tests Rust réussis**, vérification et compilation Swift, paquet signé ad hoc et rendu SwiftUI contrôlé.

## Utilisation

- **Réglages → Modèle de transcription → Décodage Whisper rapide** : décodage glouton, optionnel. Le mode normal reste la valeur par défaut. Les autres moteurs conservent leur stratégie.
- **Réglages → Intervenants** : télécharger les deux modèles (environ 47 Mo au total).
- Activer **Garder l’audio**, enregistrer, puis dans l’historique ouvrir le menu des intervenants au survol d’une dictée. Choisir la détection automatique ou un nombre connu de voix.
- Les segments horodatés apparaissent sous la dictée. **Copier avec les intervenants** exporte les numéros et le texte ; le bouton de copie habituel garde la dictée originale.

Les numéros sont stables dans un même enregistrement, par ordre d’apparition. Il ne s’agit pas de reconnaître des personnes nominativement ni de retrouver la même personne entre deux enregistrements. La transcription des échanges conserve les paroles sans reformulation Apple Intelligence, raccourcis vocaux ou commandes de mise en forme.

## Changements

- État Whisper créé au chargement et réutilisé, accès aux moteurs sérialisé pour protéger leur état natif.
- Chargements de modèles sérialisés ; résultats obsolètes ignorés et chargements en attente dépassés abandonnés.
- Délai Apple Intelligence couvrant aussi l’attente d’un autre appel et le démarrage du helper. Une session déjà préparée n’est plus recréée pour les mêmes instructions.
- Sauvegarde WAV sur le fil de transcription, hors de la boucle de l’interface.
- Filtre passe-bas de 63 coefficients avant réduction de fréquence du micro ; correction du premier échantillon et prise en charge WAV PCM 8/16/24/32 bits, flottant et stéréo.
- Silence numérique ignoré avant l’inférence. Les phrases réellement prononçables (« merci d’avoir regardé », « Radio-Canada ») ne sont plus supprimées par une liste noire.
- Audio long des moteurs ONNX hors flux découpé en fenêtres d’au plus 25 secondes, avec recherche d’une pause et couverture continue des échantillons.
- Analyse locale via Pyannote 3.0 + NVIDIA TitaNet small, modèles gardés en mémoire après la première analyse. Un traitement d’historique à la fois, exécuté hors de la boucle de l’interface.
- Résultats des intervenants dans une table SQLite séparée ; migration additive et dictées originales conservées. Protection contre les résultats tardifs après suppression, y compris si SQLite réutilise un identifiant.
- Build : erreurs Swift propagées, cible macOS 14 explicite pour Rust/CMake et interface, macOS 26 pour le helper, garde de disponibilité sur l’API d’erreur introduite en macOS 27. Liaison du runtime Clang nécessaire aux contrôles de disponibilité Metal lors de la compilation Rust pour un ancien macOS.

## Mesures reproductibles

Phrase française de 7,637 s, synthétisée avec la voix macOS Thomas, Whisper Turbo Q5. Même modèle, même audio, trois passages à chaud après un premier passage exclu. Médiane du temps d’inférence, hors chargement, reformulation et collage.

| Configuration | Médiane |
|---|---:|
| Moteur précédent, mode normal | 611 ms |
| Moteur modifié, mode normal | 622 ms |
| Moteur modifié, mode rapide | 548 ms |

Le mode rapide réduit ici le temps d’environ **10 %** par rapport au moteur précédent, avec une transcription identique. Le mode normal n’apporte pas de gain mesurable sur cette phrase. Ces quelques mesures ne sont pas un benchmark de qualité ni une garantie sur les autres modèles ou machines.

L’extrait public `1-two-speakers-en.wav` de sherpa-onnx donne automatiquement **deux voix et quatre prises de parole**. Diarisation et transcription Parakeet prennent **865 ms**, hors chargement. Le mode à deux voix imposées a aussi été exécuté. Les horodatages n’ont pas été évalués contre une annotation de référence complète (pas de DER calculé).

Le silence numérique produit une sortie vide avec Whisper et Parakeet. Le chemin Nemotron a été exécuté sur la phrase française. Le chemin Qwen3 a été exécuté sur un enregistrement de 53 s : 6,6 s après découpage, contre 9,1 s auparavant. Les deux versions restituent six des sept répétitions de la phrase synthétique : le découpage borne le contexte, mais ne corrige pas cette omission du modèle.

```sh
cargo test --lib
cargo run --release -- --benchmark fichier.wav ggml-large-v3-turbo-q5_0.bin
cargo run --release -- --diarize conversation.wav 0 nemo-parakeet-tdt-0.6b-v3-int8
# Le dernier argument optionnel permet un dossier de modèles de diarisation de test.
cargo run --release -- --diarize conversation.wav 2 nemo-parakeet-tdt-0.6b-v3-int8 /chemin/modeles
DIKTATION_SIGN_IDENTITY=- ./bundle.sh
```

Les sorties de cette validation, le rendu SwiftUI et les fixtures téléchargées sont dans `target/validation/` (non versionné). L’aperçu SwiftUI utilise des données fictives, sans démarrer le micro ou les raccourcis. L’app complète est compilée et signée localement ; les interactions avec le micro et le téléchargement dans l’app n’ont pas fait l’objet d’un parcours manuel complet.

## Limites

La diarisation est une analyse de l’audio conservé, pas un sous-titrage en direct ni une capture du son système. Elle est prévue pour des enregistrements de 1 seconde à 1 heure ; une seule analyse peut tourner à la fois. Les voix simultanées sont signalées, mais le signal mono n’est pas séparé en pistes : les mots peuvent être dupliqués ou attribués incorrectement. Les extraits très courts peuvent rester sans texte. Une analyse peut concurrencer une nouvelle dictée pour les ressources du Mac.

La précision sur réunions françaises longues, accents, bruit, voix ressemblantes et chevauchements reste à mesurer sur un corpus représentatif. Les tests synthétiques et l’extrait anglais ne permettent pas d’annoncer un taux d’erreur global. L’exécution sur macOS 14 et 26 demande encore une validation sur ces systèmes.

Sources des modèles et de l’extrait : [documentation officielle sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html), [modèles de segmentation](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models), [modèles de voix](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models). Chaque modèle conserve sa licence ; l’archive Pyannote inclut la sienne.
