//! Cœur de Diktation, sans interface : relève les événements du raccourci
//! global, ouvre le micro, lance whisper, reformule ou applique une commande
//! (Apple Intelligence), colle le texte dans l'app active et tient
//! l'historique.
//!
//! Tourne sur son propre fil (`run`, un tour toutes les 33 ms). Les travaux
//! longs (chargement du modèle, transcription, modèle de langage) partent sur
//! des fils à part et reviennent par un canal relevé à chaque tour.
//! L'interface (app Swift, voir `ffi.rs`) lit un instantané (`state_json`),
//! envoie des commandes (`command`) et reçoit deux événements : `changed`
//! (relire l'état) et `pill` (pastille à afficher, au rythme des tours).

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use serde::Serialize;
use serde_json::{Value, json};

use crate::engine::{self, Engine};
use crate::hotkey::{self, Event};
use crate::prefs::{self, Prefs};
use crate::store::{self, Entry, Store};
use crate::i18n::{is_french, tr};
use crate::{assist, audio, llm, macos, text, speakers};

/// Rythme pendant l'écoute, la transcription ou avec la pastille affichée.
const TICK: Duration = Duration::from_millis(33);
/// Au repos : le fil dort, réveillé tout de suite par le raccourci, les
/// commandes de l'interface ou la fin d'un travail (`wake`).
const IDLE_TICK: Duration = Duration::from_millis(500);
const BARS: usize = 18;
const MIN_SECONDS: f32 = 0.35;
const PILL_DELAY: Duration = Duration::from_millis(150);
/// Micro laissé actif après une dictée (pour enchaîner), puis mis en pause.
const MIC_LINGER: Duration = Duration::from_secs(10);
/// Après un appui abandonné : juste de quoi couvrir un double appui.
const MIC_LINGER_ABORT: Duration = Duration::from_secs(1);
const HISTORY_LIMIT: usize = 200;
const MESSAGE_FOR: Duration = Duration::from_millis(1400);
/// Apple Intelligence indisponible : on revérifie de temps en temps.
const LLM_RECHECK: Duration = Duration::from_secs(60);

/// Délai accordé au modèle selon la longueur du texte (mesuré : ~3,7 s pour
/// un email dicté de 630 caractères, outil lancé à froid). Au-delà, la
/// dictée est collée sans reformulation.
fn rewrite_timeout(text: &str) -> Duration {
    Duration::from_millis(3000 + 6 * text.chars().count() as u64).min(Duration::from_secs(20))
}

fn command_timeout(text: &str) -> Duration {
    Duration::from_millis(8000 + 8 * text.chars().count() as u64).min(Duration::from_secs(90))
}

// ── État ────────────────────────────────────────────────────────────────────

enum Phase {
    Idle,
    Listening { hands_free: bool, started: Instant, app: String },
    Transcribing,
}

/// Pastille, telle que l'interface doit l'afficher.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Pill {
    pub visible: bool,
    /// `listening`, `transcribing` ou `message`.
    pub mode: &'static str,
    pub hands_free: bool,
    pub command: bool,
    pub secs: u32,
    pub message: String,
    pub levels: Vec<f32>,
    /// App au premier plan au début de l'écoute (icône de la pastille).
    pub bundle_id: String,
}

impl Default for Pill {
    fn default() -> Self {
        Self {
            visible: false,
            mode: "listening",
            hands_free: false,
            command: false,
            secs: 0,
            message: String::new(),
            levels: vec![0.0; BARS],
            bundle_id: String::new(),
        }
    }
}

/// Ce que le modèle de langage fait du texte transcrit.
enum Assist {
    None,
    Rewrite { llm: Arc<llm::Llm>, instructions: String },
    Command { llm: Arc<llm::Llm> },
}

/// Résultats des fils de travail.
enum Msg {
    EngineLoaded { generation: u64, result: Result<(Arc<Engine>, Duration)>, name: String },
    Transcribed { result: Result<(String, String, u128)>, audio: Option<PathBuf>, seconds: f32, app: String },
    Retranscribed { id: i64, audio: PathBuf, result: Result<(String, String, u128)> },
    Speakers { id: i64, audio: PathBuf, result: Result<Vec<speakers::Turn>> },
    Changed,
}

pub struct Core {
    prefs: Prefs,
    meetings: crate::meetings::Controller,
    store: Option<Store>,
    engine: Option<Arc<Engine>>,
    engine_status: String,
    engine_failed: bool,
    engine_generation: Arc<AtomicU64>,
    analysis_id: Option<i64>,
    retranscribing_id: Option<i64>,
    diarizer: Arc<Mutex<Option<speakers::Diarizer>>>,
    phase: Phase,
    pill: Pill,
    pill_close_at: Option<Instant>,
    history: Vec<Entry>,
    accessibility: bool,
    last_permission_check: Instant,
    recording_chord: bool,
    recording_command: bool,
    last_error: Option<String>,
    /// La touche 🌐 de macOS fait autre chose (lu toutes les 2 s).
    fn_conflict: bool,
    llm: Arc<llm::Llm>,
    last_llm_check: Instant,
    /// L'écoute en cours (ou la dernière) est une consigne du mode commande.
    command_mode: bool,
    /// Bundle id de l'app au premier plan au début de l'écoute.
    bundle_id: String,
    /// Sa catégorie (pour un navigateur : celle de l'onglet actif).
    category: assist::Category,
    /// Une tâche whisper attend le modèle : (audio, durée, app, plan).
    waiting: Option<(Vec<f32>, f32, String, Assist)>,
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
    /// L'état a changé : l'interface doit le relire.
    dirty: bool,
    /// Le flux micro est préparé (après l'autorisation Micro).
    audio_started: bool,
    /// (dictées, mots, secondes), recalculé quand l'historique change.
    stats: (i64, i64, f64),
    /// Micros présents (relus à la demande des Réglages) et micro du système.
    mics: (Vec<String>, Option<String>),
}

impl Core {
    pub fn new() -> Self {
        let prefs = Prefs::load();
        let store = Store::open().map_err(|e| eprintln!("diktation: historique : {e}")).ok();
        if let Some(s) = &store
            && prefs.auto_delete
        {
            s.prune_older_than(24);
        }
        let history = store.as_ref().map(|s| s.recent(HISTORY_LIMIT)).unwrap_or_default();
        // Pendant l'accueil (premier lancement), les demandes d'autorisation
        // attendent l'étape qui les explique : l'interface envoie alors
        // `prompt_accessibility` puis `start_audio`.
        let onboarding = std::env::var("DIKTATION_ONBOARDING").is_ok_and(|v| v == "1");
        let accessibility = macos::accessibility_trusted(!onboarding);
        audio::set_preferred(Some(prefs.microphone.clone()));
        if !onboarding {
            audio::init();
        }
        hotkey::start(prefs.chord.clone());
        let (tx, rx) = channel();

        let mut core = Self {
            prefs,
            meetings: crate::meetings::Controller::new(),
            store,
            engine: None,
            engine_status: tr("Chargement du modèle…", "Loading model…").into(),
            engine_failed: false,
            engine_generation: Arc::new(AtomicU64::new(0)),
            analysis_id: None,
            retranscribing_id: None,
            diarizer: Arc::new(Mutex::new(None)),
            phase: Phase::Idle,
            pill: Pill::default(),
            pill_close_at: None,
            history,
            accessibility,
            last_permission_check: Instant::now(),
            recording_chord: false,
            recording_command: false,
            last_error: None,
            fn_conflict: macos::fn_key_usage().is_some_and(|v| v != 0),
            llm: Arc::new(llm::Llm::new()),
            last_llm_check: Instant::now(),
            command_mode: false,
            bundle_id: String::new(),
            category: assist::Category::Other,
            waiting: None,
            tx,
            rx,
            dirty: true,
            audio_started: !onboarding,
            stats: (0, 0, 0.0),
            mics: (Vec::new(), None),
        };
        core.stats = core.store.as_ref().map(|s| s.stats()).unwrap_or((0, 0, 0.0));
        core.load_engine();
        core.sync_assist();
        core
    }

    fn load_engine(&mut self) {
        let generation = self.engine_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let latest = self.engine_generation.clone();
        self.engine = None;
        self.engine_failed = false;
        self.dirty = true;
        let Some(model) = engine::resolve_model(&self.prefs.model) else {
            self.engine_failed = true;
            self.engine_status = tr("Aucun modèle de transcription installé", "No transcription model installed").into();
            if let Some((_, seconds, app, _)) = self.waiting.take() {
                self.finish(Err(anyhow::anyhow!(self.engine_status.clone())), None, seconds, app);
            }
            return;
        };
        let name = model.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        self.engine_status = if is_french() { format!("Chargement de {name}…") } else { format!("Loading {name}…") };
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            static LOAD: Mutex<()> = Mutex::new(());
            let _load = LOAD.lock().unwrap();
            if latest.load(Ordering::SeqCst) != generation { return; }
            let t = Instant::now();
            let result = Engine::load(&model).map(|e| (Arc::new(e), t.elapsed()));
            let _ = tx.send(Msg::EngineLoaded { generation, result, name });
            wake();
        });
    }

    // ── Boucle ──

    /// Un tour : événements clavier, résultats des fils, pastille.
    fn tick(&mut self) {
        if self.meetings.tick() { self.dirty = true; }
        while let Ok(msg) = self.rx.try_recv() {
            self.on_msg(msg);
        }
        for event in hotkey::drain() {
            self.on_event(event);
        }

        if self.last_permission_check.elapsed() > Duration::from_secs(2) {
            self.last_permission_check = Instant::now();
            // Accessibilité accordée après coup : on (re)lance le tap.
            let trusted = macos::accessibility_trusted(false);
            if trusted != self.accessibility {
                self.accessibility = trusted;
                self.dirty = true;
            }
            let fn_conflict = macos::fn_key_usage().is_some_and(|v| v != 0);
            if fn_conflict != self.fn_conflict {
                self.fn_conflict = fn_conflict;
                self.dirty = true;
            }
            if trusted && !hotkey::TAP_OK.load(Ordering::SeqCst) {
                hotkey::start(self.prefs.chord.clone());
                self.dirty = true;
            }
            if (self.prefs.rewrite || self.prefs.command)
                && !self.llm.is_ready()
                && self.last_llm_check.elapsed() > LLM_RECHECK
            {
                self.sync_assist();
            }
        }

        let max = Duration::from_secs(self.prefs.hands_free_max_minutes.max(1) as u64 * 60);
        let mut auto_stop = false;
        match &self.phase {
            Phase::Listening { hands_free, started, .. } => {
                if let Some(e) = audio::take_error() {
                    self.last_error = Some(format!("{} : {e}", tr("Micro", "Microphone")));
                    self.discard(false);
                    self.show_message(tr("Micro indisponible", "Microphone unavailable"));
                    return;
                }
                let level = audio::level();
                self.pill.levels.remove(0);
                self.pill.levels.push(level);
                self.pill.mode = "listening";
                self.pill.hands_free = *hands_free;
                self.pill.secs = started.elapsed().as_secs() as u32;
                auto_stop = *hands_free && started.elapsed() > max;
                // La pastille n'apparaît qu'après PILL_DELAY : fn+flèche ou
                // fn+effacer ne la font pas clignoter.
                if !self.pill.visible && started.elapsed() > PILL_DELAY {
                    self.pill.visible = true;
                }
            }
            Phase::Transcribing => {
                for l in self.pill.levels.iter_mut() {
                    *l *= 0.8;
                }
            }
            Phase::Idle => {}
        }
        if auto_stop {
            self.stop_and_transcribe();
        }
        if let Some(at) = self.pill_close_at
            && Instant::now() >= at
            && matches!(self.phase, Phase::Idle)
        {
            self.pill_close_at = None;
            self.pill.visible = false;
        }
    }

    /// Écoute, transcription, pastille ou enregistreur de raccourci : la
    /// boucle tourne à 30 Hz ; sinon elle dort.
    fn needs_fast_tick(&self) -> bool {
        self.meetings.recording()
            || !matches!(self.phase, Phase::Idle)
            || self.pill.visible
            || self.pill_close_at.is_some()
            || self.recording_chord
            || self.recording_command
    }

    fn on_msg(&mut self, msg: Msg) {
        self.dirty = true;
        match msg {
            Msg::EngineLoaded { generation, .. } if generation != self.engine_generation.load(Ordering::SeqCst) => {}
            Msg::EngineLoaded { result, name, .. } => match result {
                Ok((engine, took)) => {
                    self.engine_status = if is_french() {
                        format!("{name} prêt (chargé en {:.1} s)", took.as_secs_f32())
                    } else {
                        format!("{name} ready (loaded in {:.1} s)", took.as_secs_f32())
                    };
                    self.engine = Some(engine);
                    if let Some((samples, seconds, app, assist)) = self.waiting.take() {
                        self.spawn_transcription(samples, seconds, app, assist);
                    }
                }
                Err(e) => {
                    self.engine_failed = true;
                    self.engine_status = format!("{} : {e}", tr("Erreur du modèle", "Model error"));
                    if let Some((_samples, seconds, app, _)) = self.waiting.take() {
                        self.finish(Err(anyhow::anyhow!(tr("modèle de transcription indisponible", "transcription model unavailable"))), None, seconds, app);
                    }
                }
            },
            Msg::Transcribed { result, audio, seconds, app } => self.finish(result, audio, seconds, app),
            Msg::Retranscribed { id, audio, result } => {
                self.retranscribing_id = None;
                match result {
                    Ok((text, raw, millis)) => {
                        if let Some(s) = &self.store
                            && let Err(e) = s.update_text(id, &text, &raw, millis as i64, &audio) {
                            self.last_error = Some(e.to_string());
                        }
                        self.refresh_history();
                    }
                    Err(e) => self.last_error = Some(format!("{} : {e}", tr("Re-transcription", "Re-transcription"))),
                }
            }
            Msg::Speakers { id, audio, result } => {
                self.analysis_id = None;
                match result {
                    Ok(turns) => {
                        if let Some(store) = &self.store
                            && let Err(e) = store.update_turns(id, &turns, &audio) {
                            self.last_error = Some(e.to_string());
                        }
                        self.refresh_history();
                    }
                    Err(e) => self.last_error = Some(format!("{} : {e}", tr("Intervenants", "Speakers"))),
                }
            }
            Msg::Changed => {}
        }
    }

    fn on_event(&mut self, event: Event) {
        if self.meetings.busy() { return; }
        match event {
            Event::Press => match &self.phase {
                Phase::Idle => self.begin(false),
                Phase::Listening { hands_free: true, .. } => self.stop_and_transcribe(),
                _ => {}
            },
            Event::Release => {
                if matches!(self.phase, Phase::Listening { hands_free: false, .. }) {
                    self.stop_and_transcribe();
                }
            }
            Event::Abort => {
                if matches!(self.phase, Phase::Listening { hands_free: false, .. }) {
                    self.discard(false);
                }
            }
            Event::HandsFree => {
                if let Phase::Listening { hands_free, .. } = &mut self.phase {
                    *hands_free = true;
                    if self.prefs.sounds {
                        macos::play("Pop");
                    }
                }
            }
            Event::Cancel => {
                if matches!(self.phase, Phase::Listening { .. }) {
                    self.discard(true);
                }
            }
            Event::PasteLast => self.paste_last(),
            Event::CommandPress => {
                if matches!(self.phase, Phase::Idle) && self.prefs.command {
                    self.begin(true);
                }
            }
            Event::CommandUpgrade => match &self.phase {
                Phase::Listening { hands_free: false, .. } if self.prefs.command => {
                    self.set_command_mode(true);
                    self.prewarm();
                }
                Phase::Idle if self.prefs.command => self.begin(true),
                _ => {}
            },
            Event::CommandRelease => {
                if self.command_mode && matches!(self.phase, Phase::Listening { .. }) {
                    self.stop_and_transcribe();
                }
            }
            Event::CommandAbort => {
                if self.command_mode && matches!(self.phase, Phase::Listening { .. }) {
                    self.discard(false);
                }
            }
            Event::Recorded(flags) => {
                let keys = hotkey::keys_from_flags(flags);
                if self.recording_command {
                    if !keys.is_empty() && keys != self.prefs.chord.keys {
                        self.prefs.command_chord = hotkey::Chord { keys };
                        self.prefs.save();
                        self.sync_assist();
                    }
                    self.set_recording(false, true);
                } else if self.recording_chord {
                    if !keys.is_empty() {
                        // Les deux raccourcis ne peuvent pas être identiques.
                        let clash = keys == self.prefs.command_chord.keys;
                        if clash {
                            self.prefs.command = false;
                        }
                        self.prefs.chord = hotkey::Chord { keys };
                        hotkey::set_chord(self.prefs.chord.clone());
                        self.prefs.save();
                        if clash {
                            self.sync_assist();
                        }
                    }
                    self.set_recording(false, false);
                }
            }
        }
    }

    // ── Écoute ──

    /// Début d'une écoute : dictée ou consigne du mode commande.
    fn begin(&mut self, command: bool) {
        self.bundle_id = macos::frontmost_bundle_id().unwrap_or_default();
        let title = (self.prefs.rewrite && assist::is_browser(&self.bundle_id)).then(macos::front_window_title).flatten();
        self.category = assist::category_in(&self.bundle_id, title.as_deref());
        self.set_command_mode(command);
        self.start_listening();
        self.prewarm();
    }

    fn set_command_mode(&mut self, on: bool) {
        self.command_mode = on;
        self.pill.command = on;
        if on {
            // L'arbre d'Accessibilité de Chromium / Electron met ~2 s à
            // venir : on le demande dès l'appui.
            let bundle_id = self.bundle_id.clone();
            std::thread::spawn(move || macos::enable_accessibility_tree(&bundle_id));
        }
    }

    /// Ce que le modèle de langage fera de la transcription en cours.
    fn assist_plan(&self) -> Assist {
        if self.command_mode {
            return Assist::Command { llm: self.llm.clone() };
        }
        if !self.prefs.rewrite || !self.llm.is_ready() {
            return Assist::None;
        }
        let category = self.category;
        match assist::rewrite_instructions(category, self.prefs.tones.get(category), &self.prefs.dictionary) {
            Some(instructions) => Assist::Rewrite { llm: self.llm.clone(), instructions },
            None => Assist::None,
        }
    }

    /// Prépare le modèle pendant que l'utilisateur parle (ne bloque pas).
    fn prewarm(&self) {
        match self.assist_plan() {
            Assist::Rewrite { llm, instructions } => llm.prewarm(&instructions),
            Assist::Command { llm } => llm.prewarm(assist::command_instructions(true)),
            Assist::None => {}
        }
    }

    /// Lance ou arrête l'outil `diktation-llm` et le raccourci du mode
    /// commande selon les Réglages. Fonctions coupées : rien ne tourne.
    fn sync_assist(&mut self) {
        hotkey::set_command_chord(self.prefs.command.then(|| self.prefs.command_chord.clone()));
        self.last_llm_check = Instant::now();
        let llm = self.llm.clone();
        let wanted = self.prefs.rewrite || self.prefs.command;
        if wanted && llm.is_ready() {
            return;
        }
        // Hors du fil du cœur : une commande en cours tient l'outil jusqu'à
        // sa réponse.
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            if wanted { llm.start() } else { llm.stop() }
            let _ = tx.send(Msg::Changed);
            wake();
        });
    }

    fn start_listening(&mut self) {
        // Ne bloque pas : le fil micro a déjà été relancé par l'appui
        // (`hotkey` → `audio::arm`), une erreur remonte dans `tick`.
        audio::start();
        hotkey::LISTENING.store(true, Ordering::SeqCst);
        let app = macos::frontmost_app().unwrap_or_default();
        self.phase = Phase::Listening { hands_free: false, started: Instant::now(), app };
        self.last_error = None;
        self.pill_close_at = None;
        self.pill = Pill { command: self.command_mode, bundle_id: self.bundle_id.clone(), ..Pill::default() };
        self.dirty = true;
    }

    fn discard(&mut self, audible: bool) {
        if let Phase::Listening { .. } = std::mem::replace(&mut self.phase, Phase::Idle) {
            drop(audio::finish(MIC_LINGER_ABORT));
        }
        hotkey::LISTENING.store(false, Ordering::SeqCst);
        if audible && self.prefs.sounds {
            macos::play("Bottle");
        }
        self.pill.visible = false;
        self.dirty = true;
    }

    fn stop_and_transcribe(&mut self) {
        let Phase::Listening { app, started, .. } = std::mem::replace(&mut self.phase, Phase::Transcribing) else {
            return;
        };
        hotkey::LISTENING.store(false, Ordering::SeqCst);
        let samples = audio::finish(MIC_LINGER);
        let seconds = samples.len() as f32 / engine::SAMPLE_RATE as f32;
        // L'appui, pas l'audio (qui inclut la pré-écoute), décide si c'était
        // un effleurement.
        if started.elapsed().as_secs_f32() < MIN_SECONDS || seconds < MIN_SECONDS {
            self.phase = Phase::Idle;
            self.pill.visible = false;
            return;
        }
        if self.prefs.sounds {
            macos::play("Tink");
        }
        self.pill.mode = "transcribing";
        self.pill.visible = true;
        self.dirty = true;

        let assist = self.assist_plan();
        if self.engine.is_some() {
            self.spawn_transcription(samples, seconds, app, assist);
        } else if self.engine_failed {
            self.finish(Err(anyhow::anyhow!(tr("modèle de transcription indisponible", "transcription model unavailable"))), None, seconds, app);
        } else {
            // Le modèle charge encore (juste après le lancement).
            self.waiting = Some((samples, seconds, app, assist));
        }
    }

    fn spawn_transcription(&mut self, samples: Vec<f32>, seconds: f32, app: String, assist: Assist) {
        let Some(engine) = self.engine.clone() else { return };
        let prefs = self.prefs.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let started = Instant::now();
            // Mode commande : la sélection est lue pendant que whisper
            // transcrit la consigne.
            let command = matches!(assist, Assist::Command { .. });
            let selection = command.then(|| std::thread::spawn(read_selection));
            let mut prompt = engine::build_prompt(&prefs.dictionary, &prefs.language);
            if command {
                prompt = format!("{prompt} {}", assist::COMMAND_PROMPT).trim().to_string();
            }
            let result = engine.transcribe_with_options(&samples, &prefs.language, &prompt, prefs.fast_transcription).and_then(|o| {
                let mut text = text::process(&o.text, &prefs);
                let mut raw = o.text;
                if text.is_empty() { return Ok((text, raw, started.elapsed().as_millis())); }
                match assist {
                    Assist::None => {}
                    Assist::Rewrite { llm, instructions } => {
                        if assist::worth_rewriting(&text) {
                            text = rewrite(&llm, &instructions, text, &prefs);
                        }
                    }
                    Assist::Command { llm } => {
                        let selection = selection.and_then(|h| h.join().ok()).flatten();
                        raw = format!("{} : {text}", tr("Commande", "Command"));
                        text = run_command(&llm, &text, selection.as_deref())?;
                    }
                }
                let millis = started.elapsed().as_millis();
                if !text.is_empty() {
                    macos::paste(&text, prefs.restore_clipboard);
                }
                Ok((text, raw, millis))
            });
            let audio = if prefs.keep_audio && !command && result.as_ref().is_ok_and(|(text, _, _)| !text.is_empty()) {
                save_audio(&samples)
            } else { None };
            let _ = tx.send(Msg::Transcribed { result, audio, seconds, app });
            wake();
        });
    }

    fn finish(&mut self, result: Result<(String, String, u128)>, audio: Option<PathBuf>, seconds: f32, app: String) {
        self.phase = Phase::Idle;
        self.dirty = true;
        match result {
            Ok((text, raw, millis)) => {
                if text.is_empty() {
                    self.show_message(tr("Rien entendu", "Didn't catch that"));
                } else {
                    self.pill.visible = false;
                }
                if text.is_empty() {
                    return;
                }
                // Respect a privacy change made while inference was running.
                let audio = if self.prefs.keep_audio { audio } else {
                    if let Some(path) = audio { let _ = std::fs::remove_file(path); }
                    None
                };
                if let Some(store) = &self.store {
                    let _ = store.add(&text, &raw, &app, seconds, millis as i64, audio.as_ref());
                    if self.prefs.auto_delete {
                        store.prune_older_than(24);
                    }
                }
                self.refresh_history();
            }
            Err(e) => {
                let msg = format!("{e}");
                self.last_error = Some(msg.clone());
                let short = if !self.command_mode {
                    tr("Échec de la transcription", "Transcription failed").to_string()
                } else if msg.chars().count() <= 32 {
                    msg
                } else {
                    tr("Échec du mode commande", "Command failed").to_string()
                };
                self.show_message(&short);
            }
        }
    }

    fn show_message(&mut self, text: &str) {
        self.pill.mode = "message";
        self.pill.message = text.to_string();
        self.pill.visible = true;
        self.pill_close_at = Some(Instant::now() + MESSAGE_FOR);
    }

    fn paste_last(&self) {
        if let Some(text) = self.store.as_ref().and_then(|s| s.last_text()) {
            let restore = self.prefs.restore_clipboard;
            std::thread::spawn(move || macos::paste(&text, restore));
        }
    }

    fn retranscribe(&mut self, id: i64) {
        if self.retranscribing_id.is_some() || self.analysis_id.is_some() || !matches!(self.phase, Phase::Idle) { return; }
        let Some(entry) = self.history.iter().find(|e| e.id == id) else { return };
        let (Some(engine), Some(path)) = (self.engine.clone(), entry.audio.clone()) else { return };
        self.retranscribing_id = Some(id);
        self.dirty = true;
        let prefs = self.prefs.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = (|| {
                let samples = audio::load_wav(&path)?;
                let prompt = engine::build_prompt(&prefs.dictionary, &prefs.language);
                let out = engine.transcribe_with_options(&samples, &prefs.language, &prompt, prefs.fast_transcription)?;
                Ok((text::process(&out.text, &prefs), out.text, out.millis))
            })();
            let _ = tx.send(Msg::Retranscribed { id, audio: path, result });
            wake();
        });
    }

    fn analyze_speakers(&mut self, id: i64, count: usize) {
        if self.analysis_id.is_some() || self.retranscribing_id.is_some() || !matches!(self.phase, Phase::Idle) { return; }
        if !speakers::installed() {
            self.last_error = Some(tr("Téléchargez les deux modèles d’intervenants dans les réglages.",
                "Download both speaker models in Settings.").into());
            self.dirty = true;
            return;
        }
        let Some(entry) = self.history.iter().find(|e| e.id == id) else { return };
        let (Some(engine), Some(path)) = (self.engine.clone(), entry.audio.clone()) else { return };
        self.analysis_id = Some(id);
        self.last_error = None;
        self.dirty = true;
        let prefs = self.prefs.clone();
        let diarizer = self.diarizer.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = (|| {
                let samples = audio::load_wav(&path)?;
                let mut slot = diarizer.lock().map_err(|_| anyhow::anyhow!("speaker engine unavailable"))?;
                if slot.is_none() { *slot = Some(speakers::Diarizer::load(&engine::install_dir())?); }
                slot.as_ref().unwrap().analyze(&samples, &engine, &prefs, count)
            })();
            let _ = tx.send(Msg::Speakers { id, audio: path, result });
            wake();
        });
    }

    fn refresh_history(&mut self) {
        self.history = self.store.as_ref().map(|s| s.recent(HISTORY_LIMIT)).unwrap_or_default();
        self.stats = self.store.as_ref().map(|s| s.stats()).unwrap_or((0, 0, 0.0));
        self.dirty = true;
    }

    fn set_recording(&mut self, on: bool, command: bool) {
        self.recording_chord = on && !command;
        self.recording_command = on && command;
        hotkey::RECORDING_CHORD.store(on, Ordering::SeqCst);
        self.dirty = true;
    }

    /// Remplace les Réglages (envoyés en entier par l'interface).
    fn set_prefs(&mut self, new: Prefs) {
        let old = std::mem::replace(&mut self.prefs, new);
        self.prefs.save();
        if self.prefs.microphone != old.microphone {
            audio::set_preferred(Some(self.prefs.microphone.clone()));
        }
        if self.prefs.model != old.model {
            self.load_engine();
        }
        if self.prefs.chord != old.chord {
            hotkey::set_chord(self.prefs.chord.clone());
        }
        if (self.prefs.rewrite, self.prefs.command, &self.prefs.command_chord)
            != (old.rewrite, old.command, &old.command_chord)
        {
            self.sync_assist();
        }
        if self.prefs.auto_delete
            && !old.auto_delete
            && let Some(s) = &self.store
        {
            s.prune_older_than(24);
            self.refresh_history();
        }
        self.dirty = true;
    }

    // ── Interface ──

    /// Commande de l'interface : `{"cmd": "...", ...}`.
    pub fn command(&mut self, v: &Value) {
        let available = matches!(self.phase, Phase::Idle) && self.analysis_id.is_none() && self.retranscribing_id.is_none();
        if self.meetings.command(v, self.engine.clone(), &self.prefs, available) { self.dirty = true; return; }
        if self.meetings.busy() && matches!(v["cmd"].as_str(), Some("retranscribe" | "analyze_speakers" | "reload_model")) { return; }
        let id = v.get("id").and_then(Value::as_i64);
        let on = v.get("on").and_then(Value::as_bool).unwrap_or(false);
        match v.get("cmd").and_then(Value::as_str).unwrap_or("") {
            "set_prefs" => match v.get("prefs").map(|p| serde_json::from_value::<Prefs>(p.clone())) {
                Some(Ok(p)) => self.set_prefs(p),
                Some(Err(e)) => eprintln!("diktation: réglages refusés : {e}"),
                None => {}
            },
            "delete" => {
                if let (Some(id), Some(s)) = (id, &self.store) {
                    s.delete(id);
                    self.refresh_history();
                }
            }
            "clear_history" => {
                if let Some(s) = &self.store {
                    s.clear();
                    self.refresh_history();
                }
            }
            "retranscribe" => {
                if let Some(id) = id {
                    self.retranscribe(id)
                }
            }
            "analyze_speakers" => {
                if let Some(id) = id { self.analyze_speakers(id, v["speakers"].as_u64().unwrap_or(0).min(20) as usize); }
            }
            "refresh_models" => { self.dirty = true; }
            "paste_last" => self.paste_last(),
            "record_chord" => self.set_recording(on, false),
            "record_command" => self.set_recording(on, true),
            "prompt_accessibility" => {
                macos::accessibility_trusted(true);
                macos::open_privacy_pane("Privacy_Accessibility");
            }
            "reload_model" => self.load_engine(),
            "list_mics" => {
                // Énumération CoreAudio : seulement quand les Réglages s'ouvrent.
                self.mics = audio::list_inputs();
                self.dirty = true;
            }
            "start_audio" => {
                audio::init();
                self.audio_started = true;
                self.dirty = true;
            }
            "dismiss_error" => {
                self.last_error = None;
                self.dirty = true;
            }
            other => eprintln!("diktation: commande inconnue {other:?}"),
        }
    }

    /// Instantané complet pour l'interface.
    pub fn state_json(&self) -> String {
        let (count, words, seconds) = self.stats;
        let llm = match self.llm.status() {
            llm::Status::Ready => json!({ "state": "ready", "reason": "" }),
            llm::Status::Unknown => json!({ "state": "unknown", "reason": "" }),
            llm::Status::Unavailable(r) => json!({ "state": "unavailable", "reason": r }),
        };
        let active_model = self.engine.as_ref().map(|e| e.model.clone());
        let installed = engine::available_models();
        let models: Vec<Value> = installed
            .iter()
            .map(|path| {
                let file = engine::id_of(path);
                let label = engine::spec(&file).map_or("?", |m| m.label());
                let loaded = active_model.as_ref() == Some(path);
                json!({ "file": file, "label": label, "loaded": loaded })
            })
            .collect();
        // Catalogue pour l'accueil et les Réglages : ce qui peut se télécharger.
        let catalog: Vec<Value> = engine::MODELS
            .iter()
            .map(|m| {
                let have = installed.iter().any(|p| engine::id_of(p) == m.file);
                json!({ "file": m.file, "label": m.label(), "bytes": m.bytes,
                        "engine": m.kind.id(),
                        "archive": m.is_archive(),
                        "archive_dir": m.archive_dir(),
                        "download": { "name": m.download().0, "url": m.download().1 },
                        "supports_language": m.supports(&self.prefs.language),
                        "recommended": m.recommended, "installed": have })
            })
            .collect();
        let history: Vec<Value> = self
            .history
            .iter()
            .map(|e| {
                json!({
                    "id": e.id, "at": e.at, "text": e.text, "app": e.app, "seconds": e.seconds,
                    "millis": e.millis, "turns": e.turns, "has_audio": e.audio.as_ref().is_some_and(|p| p.exists()),
                })
            })
            .collect();
        let state = json!({
            "prefs": self.prefs,
            "meetings": self.meetings.state(),
            "chord_label": self.prefs.chord.label(),
            "command_chord_label": self.prefs.command_chord.label(),
            "history": history,
            "stats": { "count": count, "words": words, "seconds": seconds },
            "engine": { "ready": self.engine.is_some(), "failed": self.engine_failed, "status": self.engine_status },
            "accessibility": self.accessibility,
            "hotkey_active": hotkey::TAP_OK.load(Ordering::SeqCst),
            "fn_conflict": self.fn_conflict,
            "llm": llm,
            "recording_chord": self.recording_chord,
            "recording_command": self.recording_command,
            "last_error": self.last_error,
            "busy": self.meetings.busy() || !matches!(self.phase, Phase::Idle),
            "models": models,
            "catalog": catalog,
            "speaker_models": speakers::catalog(),
            "speakers_ready": speakers::installed(),
            "analysis_id": self.analysis_id,
            "retranscribing_id": self.retranscribing_id,
            "install_dir": engine::install_dir().display().to_string(),
            "audio_started": self.audio_started,
            "microphones": self.mics.0,
            "default_microphone": self.mics.1,
            "model_dirs": engine::model_dirs().iter().map(|d| d.display().to_string()).collect::<Vec<_>>(),
            "data_dir": prefs::data_dir().display().to_string(),
            "languages": prefs::LANGUAGES.iter().map(|(c, l)| json!({ "code": c, "label": l })).collect::<Vec<_>>(),
            "categories": assist::Category::ALL.iter().map(|c| json!({
                "id": category_key(*c), "label": c.label(), "examples": c.examples(),
                "tone": self.prefs.tones.get(*c),
            })).collect::<Vec<_>>(),
            "tones": assist::Tone::ALL.iter().map(|t| json!({ "id": t, "label": t.label() })).collect::<Vec<_>>(),
        });
        state.to_string()
    }
}

/// Nom du champ de `Tones` pour une catégorie.
fn category_key(c: assist::Category) -> &'static str {
    match c {
        assist::Category::Email => "email",
        assist::Category::WorkChat => "work_chat",
        assist::Category::PersonalChat => "personal_chat",
        assist::Category::Other => "other",
    }
}

// ── Fil du cœur ─────────────────────────────────────────────────────────────

pub static CORE: Mutex<Option<Core>> = Mutex::new(None);

static WAKE: (Mutex<bool>, Condvar) = (Mutex::new(false), Condvar::new());

/// Réveille le fil du cœur avant la fin de son attente.
pub fn wake() {
    let (flag, cv) = &WAKE;
    *flag.lock().unwrap() = true;
    cv.notify_one();
}

fn wait(timeout: Duration) {
    let (flag, cv) = &WAKE;
    let guard = flag.lock().unwrap();
    let (mut guard, _) = cv.wait_timeout_while(guard, timeout, |woken| !*woken).unwrap();
    *guard = false;
}

/// Lance le cœur sur son fil. `emit` reçoit les événements (JSON) depuis ce
/// fil.
pub fn run(emit: impl Fn(&str) + Send + 'static) {
    std::thread::Builder::new()
        .name("diktation-core".into())
        .spawn(move || {
            let core = Core::new();
            *CORE.lock().unwrap() = Some(core);
            let mut last_pill = Pill::default();
            let mut active = true;
            loop {
                wait(if active { TICK } else { IDLE_TICK });
                let (changed, pill) = {
                    let mut guard = CORE.lock().unwrap();
                    let Some(core) = guard.as_mut() else { break };
                    core.tick();
                    active = core.needs_fast_tick();
                    (std::mem::take(&mut core.dirty), core.pill.clone())
                };
                if changed {
                    emit(r#"{"type":"changed"}"#);
                }
                if pill != last_pill && (pill.visible || last_pill.visible) {
                    let mut v = serde_json::to_value(&pill).unwrap_or_default();
                    v["type"] = "pill".into();
                    emit(&v.to_string());
                }
                last_pill = pill;
            }
        })
        .expect("fil du cœur");
}

// ── Modèle de langage ───────────────────────────────────────────────────────

/// Reformule `text` ; en cas d'échec ou de réponse douteuse, `text` tel quel.
pub fn rewrite(llm: &llm::Llm, instructions: &str, text: String, prefs: &Prefs) -> String {
    let t = Instant::now();
    let keep: Vec<&str> =
        prefs.snippets.iter().map(|s| s.text.as_str()).chain(prefs.dictionary.iter().map(String::as_str)).collect();
    match llm.respond(instructions, &assist::rewrite_prompt(&text), assist::max_tokens_for(&text), rewrite_timeout(&text)) {
        Ok(out) => match assist::accept_rewrite(&text, &out, &keep) {
            Some(rewritten) => {
                eprintln!("diktation: reformulé en {} ms", t.elapsed().as_millis());
                rewritten
            }
            None => {
                eprintln!("diktation: reformulation écartée : {out:?}");
                text
            }
        },
        Err(e) => {
            eprintln!("diktation: reformulation : {e}");
            text
        }
    }
}

/// Texte sélectionné dans l'app active : Accessibilité, sinon ⌘C. Si l'arbre
/// de l'app vient d'être demandé (Chromium, Electron), on lui laisse jusqu'à
/// 0,8 s pendant que whisper transcrit.
pub fn read_selection() -> Option<String> {
    let deadline = Instant::now() + Duration::from_millis(800);
    loop {
        match macos::selected_text() {
            macos::Selection::Text(s) => return Some(s),
            macos::Selection::Empty => return None,
            macos::Selection::Unknown
                if Instant::now() < deadline && macos::tree_recently_enabled(Duration::from_secs(4)) =>
            {
                std::thread::sleep(Duration::from_millis(100))
            }
            macos::Selection::Unknown => return macos::copy_selection(),
        }
    }
}

/// Mode commande : applique la consigne dictée à la sélection, ou rédige le
/// texte demandé s'il n'y a pas de sélection.
pub fn run_command(llm: &llm::Llm, instruction: &str, selection: Option<&str>) -> Result<String> {
    if instruction.trim().is_empty() {
        anyhow::bail!(tr("Consigne non comprise", "Instruction not understood"));
    }
    if selection.is_some_and(|s| s.chars().count() > assist::MAX_SELECTION) {
        anyhow::bail!(tr("Sélection trop longue", "Selection too long"));
    }
    let max_tokens = selection.map_or(1200, assist::max_tokens_for);
    let out = llm.respond(
        assist::command_instructions(selection.is_some()),
        &assist::command_prompt(instruction, selection),
        max_tokens,
        command_timeout(selection.unwrap_or(instruction)),
    )?;
    let out = assist::clean_command_output(&out);
    if out.is_empty() {
        anyhow::bail!(tr("Réponse vide du modèle", "The model returned nothing"));
    }
    Ok(out)
}

fn save_audio(samples: &[f32]) -> Option<PathBuf> {
    let dir = store::audio_dir();
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("{}.wav", chrono::Local::now().format("%Y%m%d-%H%M%S%.3f")));
    audio::save_wav(&path, samples).ok()?;
    Some(path)
}
