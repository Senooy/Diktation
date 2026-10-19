//! Transcription locale avec whisper.cpp (via `whisper-rs`, accéléré Metal).
//!
//! Le modèle est chargé une seule fois, au démarrage, puis gardé en mémoire :
//! une dictée ne paie que le décodage, pas le chargement (1,6 Go pour
//! `large-v3-turbo`). Rien ne quitte le Mac.
//!
//! Réglages orientés dictée : recherche en faisceau, langue imposée (ou
//! « auto »), pas de contexte entre deux dictées, amorce (`initial_prompt`)
//! construite avec le dictionnaire de l'utilisateur pour bien écrire les noms
//! propres. Les phrases fantômes que whisper invente sur un silence
//! (« Sous-titrage Société Radio-Canada », « Merci d'avoir regardé »…) sont
//! écartées.

use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result, bail};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// Échantillonnage attendu par whisper.
pub const SAMPLE_RATE: u32 = 16_000;

/// Modèles reconnus, par ordre de préférence quand plusieurs sont installés.
pub struct ModelSpec {
    pub file: &'static str,
    label_fr: &'static str,
    label_en: &'static str,
    /// Taille exacte du fichier publié (contrôle du téléchargement).
    pub bytes: u64,
    pub recommended: bool,
}

impl ModelSpec {
    pub fn label(&self) -> &'static str {
        crate::i18n::tr(self.label_fr, self.label_en)
    }

    pub fn url(&self) -> String {
        format!("{DOWNLOAD_BASE}{}", self.file)
    }
}

/// Modèles officiels de whisper.cpp, sur Hugging Face.
pub const DOWNLOAD_BASE: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

pub const MODELS: [ModelSpec; 4] = [
    ModelSpec {
        file: "ggml-large-v3-turbo.bin",
        label_fr: "Turbo (recommandé)",
        label_en: "Turbo (recommended)",
        bytes: 1_624_555_275,
        recommended: true,
    },
    ModelSpec {
        file: "ggml-large-v3-turbo-q5_0.bin",
        label_fr: "Turbo compact",
        label_en: "Turbo compact",
        bytes: 574_041_195,
        recommended: false,
    },
    ModelSpec {
        file: "ggml-large-v3.bin",
        label_fr: "Large v3 (le plus précis, plus lent)",
        label_en: "Large v3 (most accurate, slower)",
        bytes: 3_095_033_483,
        recommended: false,
    },
    ModelSpec { file: "ggml-small.bin", label_fr: "Small (rapide)", label_en: "Small (fast)", bytes: 487_601_967, recommended: false },
];

pub fn spec(file: &str) -> Option<&'static ModelSpec> {
    MODELS.iter().find(|m| m.file == file)
}

/// Dossier où l'app installe les modèles téléchargés.
pub fn install_dir() -> PathBuf {
    crate::prefs::data_dir().join("models")
}

/// Dossiers où chercher les modèles : celui de l'app, puis le cache whisper
/// partagé (déjà rempli par Harness / whisper.cpp sur ce Mac).
pub fn model_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![install_dir()];
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(&home).join(".cache/whisper"));
    }
    dirs.push(PathBuf::from("/opt/homebrew/share/whisper.cpp/models"));
    dirs
}

/// Modèles présents sur le disque, dans l'ordre de `MODELS`.
pub fn available_models() -> Vec<PathBuf> {
    let dirs = model_dirs();
    MODELS
        .iter()
        // Un téléchargement interrompu laisse un fichier incomplet : on
        // n'accepte que la taille exacte.
        .filter_map(|m| {
            dirs.iter().map(|d| d.join(m.file)).find(|p| std::fs::metadata(p).is_ok_and(|md| md.len() == m.bytes))
        })
        .collect()
}

/// Modèle préféré s'il existe, sinon le premier disponible.
pub fn resolve_model(pref: &str) -> Option<PathBuf> {
    let models = available_models();
    models
        .iter()
        .find(|p| p.file_name().is_some_and(|n| n == pref))
        .or_else(|| models.first())
        .cloned()
}

pub struct Engine {
    ctx: WhisperContext,
    pub model: PathBuf,
}

/// Résultat d'une transcription.
pub struct Output {
    pub text: String,
    pub millis: u128,
}

impl Engine {
    pub fn load(model: &Path) -> Result<Self> {
        whisper_rs::install_logging_hooks();
        let mut params = WhisperContextParameters::default();
        params.use_gpu = true;
        params.flash_attn = true;
        let path = model.to_str().context("chemin du modèle non UTF-8")?;
        let ctx = WhisperContext::new_with_params(path, params)
            .map_err(|e| anyhow::anyhow!("chargement de {path} : {e}"))?;
        Ok(Self { ctx, model: model.to_path_buf() })
    }

    /// Transcrit des échantillons 16 kHz mono f32.
    pub fn transcribe(&self, samples: &[f32], language: &str, prompt: &str) -> Result<Output> {
        let started = std::time::Instant::now();
        if samples.len() < (SAMPLE_RATE as usize) / 4 {
            bail!(crate::i18n::tr("enregistrement trop court", "recording too short"));
        }
        // whisper rate les débuts de moins d'une seconde : on complète par du
        // silence jusqu'à 1,1 s.
        let min = SAMPLE_RATE as usize * 11 / 10;
        let padded;
        let data = if samples.len() < min {
            let mut v = samples.to_vec();
            v.resize(min, 0.0);
            padded = v;
            &padded[..]
        } else {
            samples
        };

        let mut state = self.ctx.create_state().map_err(|e| anyhow::anyhow!("état whisper : {e}"))?;
        let mut params = FullParams::new(SamplingStrategy::BeamSearch { beam_size: 5, patience: -1.0 });
        let lang = if language == "auto" { None } else { Some(language) };
        params.set_language(lang);
        params.set_n_threads(threads());
        params.set_no_context(true);
        params.set_no_timestamps(true);
        params.set_suppress_blank(true);
        params.set_suppress_nst(true);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        if !prompt.is_empty() {
            params.set_initial_prompt(prompt);
        }
        state.full(params, data).map_err(|e| anyhow::anyhow!("transcription : {e}"))?;

        let mut text = String::new();
        for segment in state.as_iter() {
            if segment.no_speech_probability() > 0.8 {
                continue;
            }
            let part = segment.to_str_lossy().map(|s| s.into_owned()).unwrap_or_default();
            let part = part.trim();
            if part.is_empty() || is_ghost(part) {
                continue;
            }
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(part);
        }
        Ok(Output { text, millis: started.elapsed().as_millis() })
    }
}

fn threads() -> i32 {
    std::thread::available_parallelism().map(|n| n.get().min(8) as i32).unwrap_or(4)
}

/// Phrases que whisper produit sur un silence ou un bruit (sous-titres de son
/// corpus d'entraînement).
fn is_ghost(s: &str) -> bool {
    let l = s.to_lowercase();
    const GHOSTS: [&str; 12] = [
        "sous-titrage",
        "sous-titres réalisés",
        "amara.org",
        "radio-canada",
        "merci d'avoir regardé",
        "abonnez-vous",
        "thanks for watching",
        "thank you for watching",
        "subtitles by",
        "[musique]",
        "[music]",
        "(musique)",
    ];
    GHOSTS.iter().any(|g| l.contains(g)) || (l.starts_with('[') && l.ends_with(']'))
}

/// Amorce whisper : une phrase naturelle qui contient les mots du
/// dictionnaire (whisper imite l'orthographe de ce qu'il vient de « lire »).
pub fn build_prompt(words: &[String], language: &str) -> String {
    let words: Vec<&str> = words.iter().map(|w| w.trim()).filter(|w| !w.is_empty()).collect();
    if words.is_empty() {
        return String::new();
    }
    // whisper ne garde que les ~220 derniers jetons de l'amorce.
    let list = words.iter().take(80).copied().collect::<Vec<_>>().join(", ");
    match language {
        "en" => format!("Glossary: {list}."),
        _ => format!("Vocabulaire : {list}."),
    }
}
