# Mises à jour de Diktation

À partir de 1.2.0, l’application utilise Sparkle 2.10.1. Elle vérifie chaque jour
les nouvelles versions et peut les télécharger en arrière-plan pour les installer
à sa fermeture. Les réglages permettent de désactiver ces deux options. La commande
« Rechercher les mises à jour… » existe aussi dans le menu de l’application.

Les versions 1.1.1 et antérieures ne contiennent pas Sparkle : une installation
manuelle de 1.2.0 est nécessaire une seule fois.

## Protection des sessions et des données

Les vérifications sont reportées pendant une dictée, une réunion, la préparation
ou l’arrêt de la capture, une transcription ou une analyse des intervenants. Si
une session démarre après le téléchargement, le redémarrage demandé par Sparkle
attend la fin du travail. La fermeture normale termine et sauvegarde une réunion
avant de quitter. Les modèles, enregistrements et notes restent dans le dossier
de données de l’utilisateur, hors du paquet remplacé par la mise à jour.

Les requêtes de mise à jour passent par GitHub Releases. Aucun audio, texte, note
ou profil système n’y est envoyé. Le serveur reçoit nécessairement les métadonnées
habituelles d’une connexion HTTP, notamment l’adresse IP.

## Chaîne de distribution

1. `bundle.sh` récupère le framework officiel dont la version et le SHA-256 sont
   fixés dans `scripts/fetch-sparkle.sh`, puis signe l’app et ses composants.
2. `release.sh` fait notariser l’app et le DMG par Apple et agrafe leurs tickets.
3. `scripts/make-appcast.py` génère le flux à partir du seul ZIP de cette version,
   signe le ZIP et le flux avec Ed25519, puis vérifie la signature du ZIP à l’aide
   de la clé publique embarquée. Il vérifie aussi la signature du flux, la version,
   l’URL de téléchargement, la taille, l’identité de l’app et ses réglages de sécurité.
4. `scripts/publish-release.sh` exige un dépôt propre et un tag correspondant au
   commit courant. Les fichiers sont téléversés dans une release brouillon ; elle
   devient publique seulement après le succès de tous les téléversements.

Le flux est `https://github.com/Senooy/Diktation/releases/latest/download/appcast.xml`.
Les archives utilisent une URL immuable par version. Ne pas modifier un flux signé
ni remplacer les fichiers d’une version déjà publiée ; produire une nouvelle version.

## Produire une version depuis ce Mac

Le certificat Developer ID doit être accessible dans le trousseau. Pour créer un
profil de notarisation, utiliser l’invite sécurisée, sans écrire de secret dans le
code, un argument de commande ou une conversation :

```sh
xcrun notarytool store-credentials diktation-notary
```

Un profil existant peut être réutilisé via `NOTARY_PROFILE`. Facultativement,
`NOTARY_KEYCHAIN` désigne explicitement son trousseau. La clé Sparkle locale reste
dans le trousseau, sous le compte `dev.local.diktation`. Ne pas régénérer cette clé
pour une mise à jour ordinaire.

Après modification de `Cargo.toml`, mise à jour de `Cargo.lock` et rédaction de
`docs/releases/<version>.md` :

```sh
cargo test --locked --lib
python3 -m unittest discover -s tests -p test_updates.py
NOTARY_PROFILE=nom-du-profil ./release.sh
```

Après revue et enregistrement des sources, créer et pousser le tag `v<version>`.
Sans CI configurée, lancer ensuite `./scripts/publish-release.sh` pour publier les
artefacts locaux. Ne pas publier simultanément depuis le Mac et GitHub Actions.

## Construction et publication automatiques sur GitHub

Le workflow `.github/workflows/release.yml` se déclenche sur un tag `v*`, ou
manuellement en sélectionnant ce tag. Il utilise un runner macOS 26 ARM64 et un
trousseau temporaire, supprimé en fin d’exécution. Il exécute les tests, construit,
notarise, vérifie et publie la version.

Configurer l’environnement GitHub `release` avec les secrets suivants avant le
premier tag automatisé, puis définir la variable de dépôt `RELEASE_AUTOMATION_ENABLED`
à `true`. Tant que cette variable est absente, le job reste désactivé et une
publication depuis le Mac reste possible. Cette configuration implique de confier les clés de
signature au compte GitHub ; elle est distincte de leur utilisation locale.

| Secret | Contenu |
| --- | --- |
| `DEVELOPER_ID_P12` | Export P12 du certificat **et de sa clé privée**, encodé en base64 |
| `DEVELOPER_ID_PASSWORD` | Mot de passe de cet export P12 |
| `APPLE_ID` | Compte Apple utilisé pour notariser |
| `APPLE_APP_PASSWORD` | Mot de passe spécifique à l’application créé chez Apple |
| `APPLE_TEAM_ID` | Identifiant de l’équipe Developer ID |
| `SPARKLE_PRIVATE_KEY` | Clé exportée par l’outil officiel `generate_keys`, compte `dev.local.diktation` |

Conserver une sauvegarde sûre de la clé Sparkle et du certificat. Ne jamais déposer
les exports dans Git. La configuration publique `app/updates.json` ne contient
que la clé publique, le compte du trousseau et les URL.

## Vérification

Les tests Python couvrent les incohérences du flux et du paquet. Le test Swift
`tests/UpdateActivityTests.swift` couvre les 64 combinaisons d’activités qui doivent
empêcher une installation. La vérification cryptographique du ZIP s’exécute à chaque
génération du flux. Avant publication, `release.sh` exige aussi l’acceptation de
l’app et du DMG par Gatekeeper.

Références : [documentation Sparkle](https://sparkle-project.org/documentation/),
[configuration Sparkle](https://sparkle-project.org/documentation/customization/),
[images GitHub Actions](https://github.com/actions/runner-images).
