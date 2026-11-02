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

/// Moteur de reconnaissance d'un modèle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// whisper.cpp (ggml, GPU Metal) : un seul fichier `.bin`.
    Whisper,
    /// Modèles suivants : sherpa-onnx (ONNX Runtime, CPU), un dossier tiré
    /// d'une archive officielle de k2-fsa.
    /// NVIDIA Parakeet TDT (transducteur).
    Parakeet,
    /// NVIDIA Canary 180M flash.
    Canary,
    /// Alibaba Qwen3-ASR.
    Qwen3,
    /// Cohere Transcribe.
    Cohere,
    /// Useful Sensors Moonshine v2.
    Moonshine,
    /// NVIDIA Nemotron 3.5 ASR (transducteur en flux, multilingue), décodé
    /// d'un bloc à la fin de la dictée.
    Nemotron,
}

impl Kind {
    pub fn id(self) -> &'static str {
        match self {
            Kind::Whisper => "whisper",
            Kind::Parakeet => "parakeet",
            Kind::Canary => "canary",
            Kind::Qwen3 => "qwen3",
            Kind::Cohere => "cohere",
            Kind::Moonshine => "moonshine",
            Kind::Nemotron => "nemotron",
        }
    }
}

/// Modèles reconnus, par ordre de préférence quand plusieurs sont installés.
pub struct ModelSpec {
    /// Identifiant : nom du fichier (whisper) ou du dossier (sherpa-onnx).
    pub file: &'static str,
    label_fr: &'static str,
    label_en: &'static str,
    /// Taille exacte du fichier téléchargé (modèle ou archive).
    pub bytes: u64,
    pub recommended: bool,
    pub kind: Kind,
    /// Langues de dictée prises en charge (codes whisper) ; vide : toutes.
    pub languages: &'static [&'static str],
    /// Fichiers qui doivent exister dans le dossier (sherpa-onnx).
    required: &'static [&'static str],
}

/// Modèles officiels de whisper.cpp, sur Hugging Face.
const WHISPER_BASE: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";
/// Archives officielles de sherpa-onnx (k2-fsa), sur GitHub.
const SHERPA_BASE: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/";
/// Écrit dans le dossier d'un modèle sherpa-onnx une fois l'archive extraite.
pub const COMPLETE_MARKER: &str = ".diktation-complete";

impl ModelSpec {
    pub fn label(&self) -> &'static str {
        crate::i18n::tr(self.label_fr, self.label_en)
    }

    /// Archive tar.bz2 à extraire (sherpa-onnx) plutôt qu'un fichier seul.
    pub fn is_archive(&self) -> bool {
        self.kind != Kind::Whisper
    }

    /// Fichier téléchargé : (nom, adresse, taille exacte).
    pub fn download(&self) -> (String, String, u64) {
        if self.is_archive() {
            let name = format!("sherpa-onnx-{}.tar.bz2", self.file);
            (name.clone(), format!("{SHERPA_BASE}{name}"), self.bytes)
        } else {
            (self.file.into(), format!("{WHISPER_BASE}{}", self.file), self.bytes)
        }
    }

    /// Dossier où l'archive s'extrait (son dossier racine).
    pub fn archive_dir(&self) -> String {
        format!("sherpa-onnx-{}", self.file)
    }

    /// Le modèle est-il complet dans `dir` ?
    fn installed_in(&self, dir: &Path) -> Option<PathBuf> {
        if self.is_archive() {
            let root = dir.join(self.archive_dir());
            let ok = root.join(COMPLETE_MARKER).exists() && self.required.iter().all(|f| root.join(f).exists());
            ok.then_some(root)
        } else {
            Some(dir.join(self.file)).filter(|p| std::fs::metadata(p).is_ok_and(|md| md.len() == self.bytes))
        }
    }

    pub fn supports(&self, language: &str) -> bool {
        self.languages.is_empty() || self.languages.contains(&language)
    }
}

const fn whisper(file: &'static str, fr: &'static str, en: &'static str, bytes: u64, recommended: bool) -> ModelSpec {
    ModelSpec { file, label_fr: fr, label_en: en, bytes, recommended, kind: Kind::Whisper, languages: &[], required: &[] }
}

pub const MODELS: [ModelSpec; 11] = [
    whisper("ggml-large-v3-turbo.bin", "Whisper Turbo (recommandé)", "Whisper Turbo (recommended)", 1_624_555_275, true),
    ModelSpec {
        file: "nemo-parakeet-tdt-0.6b-v3-int8",
        label_fr: "NVIDIA Parakeet v3 · très rapide, 25 langues européennes",
        label_en: "NVIDIA Parakeet v3 · very fast, 25 European languages",
        bytes: 487_170_055,
        recommended: false,
        kind: Kind::Parakeet,
        languages: &["fr", "en", "es", "de", "it", "pt", "nl", "pl", "sv", "da", "fi", "el", "cs", "sk", "hu", "ro", "bg", "hr", "sl", "et", "lv", "lt", "mt", "ru", "uk"],
        required: &["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
    },
    ModelSpec {
        file: "nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11",
        label_fr: "NVIDIA Nemotron 3.5 · le plus récent, multilingue",
        label_en: "NVIDIA Nemotron 3.5 · newest, multilingual",
        bytes: 475_271_763,
        recommended: false,
        kind: Kind::Nemotron,
        languages: &[],
        required: &["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
    },
    ModelSpec {
        file: "qwen3-asr-0.6B-int8-2026-03-25",
        label_fr: "Qwen3-ASR 0.6B · récent, 52 langues",
        label_en: "Qwen3-ASR 0.6B · recent, 52 languages",
        bytes: 878_702_423,
        recommended: false,
        kind: Kind::Qwen3,
        languages: &[],
        required: &["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer"],
    },
    ModelSpec {
        file: "cohere-transcribe-14-lang-int8-2026-04-01",
        label_fr: "Cohere Transcribe · le plus précis, 14 langues",
        label_en: "Cohere Transcribe · most accurate, 14 languages",
        bytes: 1_699_791_751,
        recommended: false,
        kind: Kind::Cohere,
        languages: &["en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "ko", "vi"],
        required: &["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"],
    },
    ModelSpec {
        file: "nemo-canary-180m-flash-en-es-de-fr-int8",
        label_fr: "NVIDIA Canary 180M flash · ultra léger (fr, en, es, de)",
        label_en: "NVIDIA Canary 180M flash · ultra light (en, fr, es, de)",
        bytes: 153_692_328,
        recommended: false,
        kind: Kind::Canary,
        languages: &["en", "fr", "es", "de"],
        required: &["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"],
    },
    ModelSpec {
        file: "nemo-parakeet-unified-en-0.6b-int8-non-streaming",
        label_fr: "NVIDIA Parakeet Unified · anglais",
        label_en: "NVIDIA Parakeet Unified · English",
        bytes: 501_350_460,
        recommended: false,
        kind: Kind::Parakeet,
        languages: &["en"],
        required: &["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
    },
    ModelSpec {
        file: "moonshine-base-en-quantized-2026-02-27",
        label_fr: "Moonshine base · anglais, instantané",
        label_en: "Moonshine base · English, instant",
        bytes: 111_266_225,
        recommended: false,
        kind: Kind::Moonshine,
        languages: &["en"],
        required: &["encoder_model.ort", "decoder_model_merged.ort", "tokens.txt"],
    },
    whisper("ggml-large-v3-turbo-q5_0.bin", "Whisper Turbo compact", "Whisper Turbo compact", 574_041_195, false),
    whisper("ggml-large-v3.bin", "Whisper Large v3 (précis, lent)", "Whisper Large v3 (accurate, slow)", 3_095_033_483, false),
    whisper("ggml-small.bin", "Whisper Small (rapide)", "Whisper Small (fast)", 487_601_967, false),
];

pub fn spec(file: &str) -> Option<&'static ModelSpec> {
    MODELS.iter().find(|m| m.file == file || m.archive_dir() == file)
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
        // n'accepte que les tailles exactes.
        .filter_map(|m| dirs.iter().find_map(|d| m.installed_in(d)))
        .collect()
}

/// Identifiant du catalogue d'un modèle installé (fichier ou dossier).
pub fn id_of(path: &Path) -> String {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    spec(&name).map_or(name, |m| m.file.to_string())
}

/// Modèle préféré s'il existe, sinon le premier disponible.
pub fn resolve_model(pref: &str) -> Option<PathBuf> {
    let models = available_models();
    models
        .iter()
        .find(|p| id_of(p) == pref)
        .or_else(|| models.first())
        .cloned()
}

pub struct Engine {
    backend: Backend,
    pub model: PathBuf,
}

enum Backend {
    Whisper(WhisperContext),
    /// Modèle en flux (Nemotron) : on lui donne toute la dictée d'un coup.
    Online(sherpa_onnx::OnlineRecognizer),
    Sherpa { recognizer: sherpa_onnx::OfflineRecognizer, kind: Kind, languages: &'static [&'static str] },
}

/// Résultat d'une transcription.
pub struct Output {
    pub text: String,
    pub millis: u128,
}

impl Engine {
    pub fn load(model: &Path) -> Result<Self> {
        let name = model.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if let Some(m) = spec(&name).filter(|m| m.kind == Kind::Nemotron) {
            return Self::load_online(model, m);
        }
        if let Some(m) = spec(&name).filter(|m| m.is_archive()) {
            return Self::load_sherpa(model, m);
        }
        whisper_rs::install_logging_hooks();
        let mut params = WhisperContextParameters::default();
        params.use_gpu = true;
        params.flash_attn = true;
        let path = model.to_str().context("chemin du modèle non UTF-8")?;
        let ctx = WhisperContext::new_with_params(path, params)
            .map_err(|e| anyhow::anyhow!("chargement de {path} : {e}"))?;
        Ok(Self { backend: Backend::Whisper(ctx), model: model.to_path_buf() })
    }

    fn load_sherpa(dir: &Path, m: &'static ModelSpec) -> Result<Self> {
        let file = |name: &str| Some(dir.join(name).to_string_lossy().into_owned());
        let mut config = sherpa_onnx::OfflineRecognizerConfig::default();
        let mc = &mut config.model_config;
        match m.kind {
            Kind::Parakeet => {
                mc.transducer = sherpa_onnx::OfflineTransducerModelConfig {
                    encoder: file("encoder.int8.onnx"),
                    decoder: file("decoder.int8.onnx"),
                    joiner: file("joiner.int8.onnx"),
                };
                mc.tokens = file("tokens.txt");
                mc.model_type = Some("nemo_transducer".into());
            }
            Kind::Canary => {
                mc.canary = sherpa_onnx::OfflineCanaryModelConfig {
                    encoder: file("encoder.int8.onnx"),
                    decoder: file("decoder.int8.onnx"),
                    src_lang: Some("fr".into()),
                    tgt_lang: Some("fr".into()),
                    use_pnc: true,
                };
                mc.tokens = file("tokens.txt");
            }
            Kind::Qwen3 => {
                mc.qwen3_asr = sherpa_onnx::OfflineQwen3ASRModelConfig {
                    conv_frontend: file("conv_frontend.onnx"),
                    encoder: file("encoder.int8.onnx"),
                    decoder: file("decoder.int8.onnx"),
                    tokenizer: file("tokenizer"),
                    // Dictées longues (mains libres) : de la marge.
                    max_total_len: 1024,
                    max_new_tokens: 512,
                    ..Default::default()
                };
                mc.tokens = Some(String::new());
            }
            Kind::Cohere => {
                mc.cohere_transcribe = sherpa_onnx::OfflineCohereTranscribeModelConfig {
                    encoder: file("encoder.int8.onnx"),
                    decoder: file("decoder.int8.onnx"),
                    language: Some("en".into()),
                    use_punct: true,
                    use_itn: true,
                };
                mc.tokens = file("tokens.txt");
            }
            Kind::Moonshine => {
                mc.moonshine = sherpa_onnx::OfflineMoonshineModelConfig {
                    encoder: file("encoder_model.ort"),
                    merged_decoder: file("decoder_model_merged.ort"),
                    ..Default::default()
                };
                mc.tokens = file("tokens.txt");
            }
            Kind::Whisper | Kind::Nemotron => unreachable!(),
        }
        mc.num_threads = threads();
        mc.debug = false;
        let recognizer = sherpa_onnx::OfflineRecognizer::create(&config)
            .with_context(|| format!("chargement de {}", dir.display()))?;
        Ok(Self { backend: Backend::Sherpa { recognizer, kind: m.kind, languages: m.languages }, model: dir.to_path_buf() })
    }

    fn load_online(dir: &Path, _m: &'static ModelSpec) -> Result<Self> {
        let file = |name: &str| Some(dir.join(name).to_string_lossy().into_owned());
        let mut config = sherpa_onnx::OnlineRecognizerConfig::default();
        config.model_config.transducer = sherpa_onnx::OnlineTransducerModelConfig {
            encoder: file("encoder.int8.onnx"),
            decoder: file("decoder.int8.onnx"),
            joiner: file("joiner.int8.onnx"),
        };
        config.model_config.tokens = file("tokens.txt");
        config.model_config.num_threads = threads();
        config.model_config.debug = false;
        let recognizer = sherpa_onnx::OnlineRecognizer::create(&config)
            .with_context(|| format!("chargement de {}", dir.display()))?;
        Ok(Self { backend: Backend::Online(recognizer), model: dir.to_path_buf() })
    }

    /// Nemotron : toute la dictée d'un bloc, puis décodage jusqu'au bout.
    /// La langue est imposée si elle est choisie, détectée sinon.
    fn transcribe_online(recognizer: &sherpa_onnx::OnlineRecognizer, samples: &[f32], language: &str, started: std::time::Instant) -> Result<Output> {
        let stream = recognizer.create_stream();
        stream.set_option("language", if language == "auto" { "auto" } else { language });
        // Un modèle en flux rate les premiers mots sans un peu de silence
        // avant (il lui faut du contexte à gauche).
        stream.accept_waveform(SAMPLE_RATE as i32, &vec![0.0; SAMPLE_RATE as usize / 2]);
        stream.accept_waveform(SAMPLE_RATE as i32, samples);
        // Silence de fin : le dernier bloc (560 ms) doit se remplir.
        stream.accept_waveform(SAMPLE_RATE as i32, &vec![0.0; SAMPLE_RATE as usize]);
        stream.input_finished();
        while recognizer.is_ready(&stream) {
            recognizer.decode(&stream);
        }
        let text = recognizer.get_result(&stream).map(|r| r.text.trim().to_string()).unwrap_or_default();
        Ok(Output { text, millis: started.elapsed().as_millis() })
    }

    /// sherpa-onnx : pas d'amorce (le dictionnaire passe par les corrections
    /// automatiques). Canary et Cohere reçoivent la langue choisie quand ils
    /// la connaissent ; les autres la détectent.
    fn transcribe_sherpa(
        recognizer: &sherpa_onnx::OfflineRecognizer,
        kind: Kind,
        languages: &[&str],
        samples: &[f32],
        language: &str,
        started: std::time::Instant,
    ) -> Result<Output> {
        let stream = recognizer.create_stream();
        let lang = if languages.contains(&language) { language } else { languages.first().copied().unwrap_or("en") };
        match kind {
            Kind::Canary => {
                stream.set_option("src_lang", lang);
                stream.set_option("tgt_lang", lang);
            }
            Kind::Cohere => stream.set_option("language", lang),
            _ => {}
        }
        // Un peu de silence en fin aide le décodeur à finir le dernier mot.
        let mut data = samples.to_vec();
        data.extend(std::iter::repeat_n(0.0, SAMPLE_RATE as usize * 3 / 10));
        stream.accept_waveform(SAMPLE_RATE as i32, &data);
        recognizer.decode(&stream);
        let text = stream.get_result().map(|r| r.text.trim().to_string()).unwrap_or_default();
        Ok(Output { text, millis: started.elapsed().as_millis() })
    }

    /// Transcrit des échantillons 16 kHz mono f32.
    pub fn transcribe(&self, samples: &[f32], language: &str, prompt: &str) -> Result<Output> {
        let started = std::time::Instant::now();
        if samples.len() < (SAMPLE_RATE as usize) / 4 {
            bail!(crate::i18n::tr("enregistrement trop court", "recording too short"));
        }
        let ctx = match &self.backend {
            Backend::Whisper(ctx) => ctx,
            Backend::Online(r) => return Self::transcribe_online(r, samples, language, started),
            Backend::Sherpa { recognizer, kind, languages } => {
                return Self::transcribe_sherpa(recognizer, *kind, languages, samples, language, started);
            }
        };
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

        let mut state = ctx.create_state().map_err(|e| anyhow::anyhow!("état whisper : {e}"))?;
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
