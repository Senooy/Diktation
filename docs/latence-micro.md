# Latence d'ouverture du micro

Mesures du 2026-10-19, MacBook Pro M5 Pro, micro intégré (48 kHz, F32). Outils :
`cargo run --release --example mic_latency | mic_pause | mic_warmup`, et l'app elle-même (journal
`open --stderr fichier.log Diktation.app`).

## Ce qui coûte

| Étape | Durée |
|---|---|
| 1re ouverture dans un processus neuf (énumération + init HAL) | 0,5 à 3,7 s |
| Chaque ouverture suivante (`default_input_config` + `build_input_stream`) | 170 à 600 ms |
| Reprise d'un flux construit puis mis en pause (`play`) → 1er tampon | 50 à 120 ms (souvent ~60) |
| Mise en pause | ~15 ms |
| Silence du micro intégré après tout démarrage (reprise ou ouverture) | ~170 ms |

Le coût est donc **à chaque ouverture**, pas seulement la première : cpal crée deux `AudioUnit`
par ouverture (une juste pour lire la plage de tailles de tampon). Le premier lancement d'un
processus ajoute l'initialisation du HAL.

Après chaque démarrage des E/S, le micro intégré rend un premier tampon bref, puis **du silence
numérique de ~90 à ~230 ms**, puis le vrai signal. C'est matériel : même délai avec une pause de
300 ms ou de 3 s, avec un tampon de 256 ou celui par défaut, et en reprise comme en ouverture
complète (il est aussi dans les WAV de l'ancienne version). Ces chiffres valent pour le micro
intégré ; un casque peut se comporter autrement (non mesuré).

En pause, `kAudioDevicePropertyDeviceIsRunningSomewhere` repasse à 0 : CoreAudio ne fait plus
tourner le micro, et c'est ce qui pilote le voyant orange.

## Ce que fait Diktation

- Le flux est construit **une fois au lancement**, sur le fil `diktation-mic`, puis mis en
  pause (le voyant s'allume ~0,2 s au lancement).
- L'appui sur le raccourci relance le flux depuis le fil du clavier (`audio::arm`), sans attendre
  le tour de l'interface (33 ms). Le fil principal ne fait que poser des drapeaux : ~1 µs.
- Après une dictée, le flux reste actif **10 s** (`MIC_LINGER`), 1 s après un appui abandonné,
  puis repasse en pause. Voyant allumé pendant l'appui + 10 s, éteint ensuite (vérifié en lisant
  l'état CoreAudio depuis un autre processus).
- Tant qu'il tourne sans dictée, les **300 ms** les plus récentes sont gardées et servent de
  pré-écoute à la dictée suivante. Conséquence : à chaud, ce qui a été dit juste avant l'appui
  peut se retrouver au début de la transcription.
- Si le micro par défaut change (casque branché), le flux est reconstruit au prochain appui.
  Chemin non testé faute d'un second micro. Si la reprise échoue (réveil après veille…), le flux
  est reconstruit au même appui ; ce cas n'a pas été provoqué en test.

## Avant / après en conditions réelles

Protocole : voix de synthèse (`say -v Thomas`) jouée par les haut-parleurs, attaque du premier mot
calée sur l'horloge hôte au moment exact d'un appui fn simulé (CGEvent), dictée collée dans
TextEdit, lecture de l'historique et du WAV gardé. « un, deux, trois » ne suffit pas : whisper
écrit « 1, 2, 3 » même quand le « un » manque dans l'audio, en complétant la suite.
« pomme, poire, cerise » sert donc de test.

| | Fil principal bloqué | Son utile après l'appui | « pomme » au début |
|---|---|---|---|
| Avant (ouverture à chaque appui) | 75 à 226 ms | ~280 à 430 ms (ouverture + ≤ 33 ms + silence du micro) | perdu 2/2 |
| Après, micro en pause (> 10 s depuis la dernière dictée) | ~1 µs | ~230 ms (reprise ~55 ms + silence du micro) | gardé 1/4 ; « un » perdu |
| Après, micro encore actif (< 10 s) | ~1 µs | 0, plus 300 ms de pré-écoute | gardé 3/3 |

Les comptes « gardé n/m » viennent de peu d'essais, et quelqu'un parlait dans la pièce pendant
certains : ils sont indicatifs. Les ~170 ms de silence du micro, eux, ont été mesurés à part
(`mic_warmup`, sans voix) et se voient comme des zéros dans les WAV.

À froid, il reste donc ~230 ms où le micro intégré n'entend rien, quoi que fasse le logiciel :
seul un micro déjà en marche l'évite. Le réglage possible est `MIC_LINGER` (plus long = plus de
dictées à chaud, voyant allumé plus longtemps).
