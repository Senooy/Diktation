//! Réglages, enregistrés en JSON dans
//! `~/Library/Application Support/Diktation/prefs.json`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::assist::Tones;
use crate::hotkey::{Chord, Key};

pub fn data_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library/Application Support/Diktation")
}

fn path() -> PathBuf {
    data_dir().join("prefs.json")
}

/// Raccourci vocal : dire `trigger` insère `text`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Snippet {
    pub trigger: String,
    pub text: String,
}

/// Correction systématique : `from` (ce que whisper écrit) devient `to`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Replacement {
    pub from: String,
    pub to: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    /// Combinaison de modificateurs à maintenir pour dicter. Deux appuis
    /// rapides passent en mains libres.
    pub chord: Chord,
    /// Code langue whisper (`fr`, `en`, `auto`…).
    pub language: String,
    /// Fichier du modèle (`ggml-large-v3-turbo.bin`).
    pub model: String,
    /// Mots à bien orthographier (amorce whisper).
    pub dictionary: Vec<String>,
    pub replacements: Vec<Replacement>,
    pub snippets: Vec<Snippet>,
    /// Retire « euh », « heu », « hum »…
    pub remove_fillers: bool,
    /// Commandes vocales « à la ligne », « nouveau paragraphe ».
    pub voice_commands: bool,
    pub sounds: bool,
    /// Garde l'audio de chaque dictée (pour re-transcrire).
    pub keep_audio: bool,
    /// Efface l'historique de plus de 24 h.
    pub auto_delete: bool,
    /// Remet le presse-papiers d'avant après le collage.
    pub restore_clipboard: bool,
    /// Arrêt automatique du mode mains libres (minutes).
    pub hands_free_max_minutes: u32,
    /// Reformule la dictée selon l'app active (Apple Intelligence, local).
    pub rewrite: bool,
    /// Ton par catégorie d'app.
    pub tones: Tones,
    /// Mode commande : une consigne dictée appliquée au texte sélectionné.
    pub command: bool,
    /// Combinaison à maintenir pour le mode commande.
    pub command_chord: Chord,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            chord: Chord::default(),
            language: if crate::i18n::is_french() { "fr" } else { "en" }.into(),
            model: "ggml-large-v3-turbo.bin".into(),
            dictionary: vec!["Diktation".into()],
            replacements: Vec::new(),
            snippets: Vec::new(),
            remove_fillers: true,
            voice_commands: true,
            sounds: true,
            keep_audio: true,
            auto_delete: false,
            restore_clipboard: true,
            hands_free_max_minutes: 10,
            rewrite: true,
            tones: Tones::default(),
            command: true,
            command_chord: Chord { keys: vec![Key::Fn, Key::Control] },
        }
    }
}

impl Prefs {
    pub fn load() -> Self {
        std::fs::read_to_string(path())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let dir = data_dir();
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let tmp = dir.join("prefs.json.tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(tmp, path());
            }
        }
    }
}

/// Langues proposées : (code whisper, libellé).
pub const LANGUAGES: [(&str, &str); 7] = [
    ("fr", "Français"),
    ("en", "English"),
    ("auto", "Auto"),
    ("es", "Español"),
    ("de", "Deutsch"),
    ("it", "Italiano"),
    ("ar", "العربية"),
];
