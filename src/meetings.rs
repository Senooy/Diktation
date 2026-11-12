//! Meeting workspace: durable notes, provisional text while recording, and a
//! final speaker-labelled transcript. Never pastes into another application.
use crate::{
    audio,
    engine::{self, Engine, SAMPLE_RATE},
    i18n::tr,
    prefs::{self, Prefs},
    speakers::{Diarizer, Turn},
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, params};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Serialize)]
pub struct Meeting {
    pub id: i64,
    pub at: i64,
    pub title: String,
    pub notes: String,
    pub status: String,
    pub seconds: f32,
    pub turns: Vec<Turn>,
    pub names: BTreeMap<String, String>,
    pub error: String,
    pub audio: String,
    pub language: String,
    pub model: String,
    pub speaker_count: usize,
    pub detail_loaded: bool,
    pub source: String,
}

struct Store(Connection, PathBuf);
impl Store {
    fn open() -> Result<Self> {
        std::fs::create_dir_all(prefs::data_dir())?;
        Self::init(
            Connection::open(prefs::data_dir().join("meetings.sqlite"))?,
            prefs::data_dir().join("meetings"),
        )
    }
    fn init(db: Connection, root: PathBuf) -> Result<Self> {
        db.execute_batch(
            "PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS meeting (
                id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
                title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'draft', seconds REAL NOT NULL DEFAULT 0,
                turns TEXT NOT NULL DEFAULT '[]', names TEXT NOT NULL DEFAULT '{}',
                error TEXT NOT NULL DEFAULT '', audio TEXT NOT NULL DEFAULT '',
                language TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '',
                speaker_count INTEGER NOT NULL DEFAULT 0
            );",
        )?;
        let has_source = {
            let mut statement = db.prepare("PRAGMA table_info(meeting)")?;
            statement
                .query_map([], |r| r.get::<_, String>(1))?
                .collect::<std::result::Result<Vec<_>, _>>()?
                .iter()
                .any(|s| s == "source")
        };
        if !has_source {
            db.execute(
                "ALTER TABLE meeting ADD COLUMN source TEXT NOT NULL DEFAULT 'microphone'",
                [],
            )?;
        }
        // Notes and already-transcribed passages survive an interrupted session.
        db.execute(
            "UPDATE meeting SET status = 'interrupted', error = ?1
            WHERE status IN ('recording','processing')",
            [tr(
                "Session interrompue. Les notes et les passages sauvegardés sont conservés.",
                "Session interrupted. Notes and saved passages were kept.",
            )],
        )?;
        Ok(Self(db, root))
    }
    fn create(&self) -> Result<i64> {
        let title = format!(
            "{} {}",
            tr("Réunion du", "Meeting"),
            chrono::Local::now().format("%d/%m/%Y %H:%M")
        );
        self.0.execute(
            "INSERT INTO meeting (at,title) VALUES (?1,?2)",
            params![chrono::Local::now().timestamp(), title],
        )?;
        Ok(self.0.last_insert_rowid())
    }
    #[cfg(test)]
    fn list(&self) -> Result<Vec<Meeting>> {
        self.list_selected(None, None)
    }

    fn list_selected(&self, selected: Option<i64>, active: Option<i64>) -> Result<Vec<Meeting>> {
        // Only the selected and active meeting need full text. Typing notes must
        // not deserialize every archived transcript on each keystroke.
        let mut st = self.0.prepare("WITH records AS (
            SELECT *, (id=COALESCE(?1,(SELECT MAX(id) FROM meeting)) OR id=COALESCE(?2,-1)) AS loaded FROM meeting)
            SELECT id,at,title,CASE WHEN loaded THEN notes ELSE '' END,status,seconds,
                CASE WHEN loaded THEN turns ELSE '[]' END,CASE WHEN loaded THEN names ELSE '{}' END,
                error,audio,language,model,speaker_count,loaded,source FROM records ORDER BY id DESC")?;
        Ok(st
            .query_map(params![selected, active], |r| {
                Ok(Meeting {
                    id: r.get(0)?,
                    at: r.get(1)?,
                    title: r.get(2)?,
                    notes: r.get(3)?,
                    status: r.get(4)?,
                    seconds: r.get(5)?,
                    turns: serde_json::from_str(&r.get::<_, String>(6)?).unwrap_or_default(),
                    names: serde_json::from_str(&r.get::<_, String>(7)?).unwrap_or_default(),
                    error: r.get(8)?,
                    audio: r.get(9)?,
                    language: r.get(10)?,
                    model: r.get(11)?,
                    speaker_count: r.get::<_, u32>(12)? as usize,
                    detail_loaded: r.get(13)?,
                    source: r.get(14)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }
    fn edit(&self, id: i64, v: &Value) -> Result<()> {
        // Worker results update different columns and cannot overwrite notes.
        for key in ["title", "notes"] {
            if let Some(value) = v[key].as_str() {
                ensure!(value.len() <= 1_000_000, "meeting text too long");
                self.0.execute(
                    &format!("UPDATE meeting SET {key} = ?2 WHERE id = ?1"),
                    params![id, value],
                )?;
            }
        }
        if let Some(names) = v.get("names") {
            let names: BTreeMap<String, String> = serde_json::from_value(names.clone())?;
            ensure!(
                names.len() <= 20 && names.values().all(|s| s.len() <= 200),
                "invalid speaker names"
            );
            self.0.execute(
                "UPDATE meeting SET names = ?2 WHERE id = ?1",
                params![id, serde_json::to_string(&names)?],
            )?;
        }
        Ok(())
    }
    fn start(&self, id: i64, prefs: &Prefs, count: usize, audio: &str) -> Result<()> {
        ensure!(count <= 20, "invalid speaker count");
        ensure!(self.0.execute("UPDATE meeting SET status='recording', language=?2, model=?3, speaker_count=?4, audio=?5, error='' WHERE id=?1 AND status='draft'",
            params![id,prefs.language,prefs.model,count as u32,audio])? == 1, "meeting is not a draft");
        Ok(())
    }
    fn status(&self, id: i64, status: &str, error: &str) -> Result<()> {
        self.0.execute(
            "UPDATE meeting SET status=?2, error=?3 WHERE id=?1",
            params![id, status, error],
        )?;
        Ok(())
    }
    fn transcript(&self, id: i64, turns: &[Turn], seconds: f32, final_result: bool) -> Result<()> {
        self.0.execute("UPDATE meeting SET turns=?2, seconds=?3, status=CASE WHEN ?4 THEN 'ready' ELSE status END
            WHERE id=?1 AND (status='recording' OR (?4 AND status='processing'))", params![id,serde_json::to_string(turns)?,seconds,final_result])?;
        Ok(())
    }
    fn delete(&self, id: i64) -> Result<()> {
        self.0.execute("DELETE FROM meeting WHERE id=?1", [id])?;
        // Meetings use their own folder; clearing dictation history cannot erase them.
        let path = self.1.join(id.to_string());
        if path.exists() {
            std::fs::remove_dir_all(path)?;
        }
        Ok(())
    }
}

enum Event {
    Preview {
        id: i64,
        end: usize,
        result: Result<String>,
    },
    Finished {
        id: i64,
        seconds: f32,
        result: Result<Vec<Turn>>,
    },
}
struct Recording {
    external: bool,
    id: i64,
    started: Instant,
    offset: usize,
    preview_busy: bool,
    engine: Arc<Engine>,
    prefs: Prefs,
    count: usize,
}

pub struct Controller {
    store: Option<Store>,
    items: Vec<Meeting>,
    recording: Option<Recording>,
    processing: Option<i64>,
    selected: Option<i64>,
    error: Option<String>,
    elapsed: u64,
    tx: mpsc::Sender<Event>,
    rx: mpsc::Receiver<Event>,
    diarizer: Arc<Mutex<Option<Diarizer>>>,
}
impl Default for Controller {
    fn default() -> Self {
        Self::new()
    }
}

impl Controller {
    pub fn new() -> Self {
        Self::with_store(Store::open())
    }
    fn with_store(store: Result<Store>) -> Self {
        let error = store.as_ref().err().map(ToString::to_string);
        let (tx, rx) = mpsc::channel();
        let mut c = Self {
            store: store.ok(),
            items: Vec::new(),
            recording: None,
            processing: None,
            selected: None,
            error,
            elapsed: 0,
            tx,
            rx,
            diarizer: Arc::new(Mutex::new(None)),
        };
        c.refresh();
        c
    }
    fn refresh(&mut self) {
        if let Some(store) = &self.store {
            match store.list_selected(
                self.selected,
                self.recording.as_ref().map(|r| r.id).or(self.processing),
            ) {
                Ok(items) => self.items = items,
                Err(e) => self.error = Some(e.to_string()),
            }
        }
    }
    pub fn busy(&self) -> bool {
        self.recording.is_some() || self.processing.is_some()
    }
    pub fn recording(&self) -> bool {
        self.recording.is_some()
    }
    pub fn state(&self) -> Value {
        json!({"items":self.items,"recording_id":self.recording.as_ref().map(|r|r.id),
            "processing_id":self.processing,"selected_id":self.selected,"elapsed":self.elapsed,"error":self.error})
    }
    pub fn command(
        &mut self,
        v: &Value,
        engine: Option<Arc<Engine>>,
        prefs: &Prefs,
        available: bool,
    ) -> bool {
        let cmd = v["cmd"].as_str().unwrap_or("");
        if !cmd.starts_with("meeting_") {
            return false;
        }
        let result = self.handle(cmd, v, engine, prefs, available);
        if let Err(e) = result {
            self.error = Some(e.to_string());
        }
        self.refresh();
        true
    }
    fn handle(
        &mut self,
        cmd: &str,
        v: &Value,
        engine: Option<Arc<Engine>>,
        prefs: &Prefs,
        available: bool,
    ) -> Result<()> {
        let id = v["id"].as_i64().unwrap_or(0);
        let store = self.store.as_ref().context("meeting storage unavailable")?;
        match cmd {
            "meeting_create" => {
                self.selected = Some(store.create()?);
                self.error = None;
            }
            "meeting_select" => {
                if self.items.iter().any(|m| m.id == id) {
                    self.selected = Some(id);
                }
            }
            "meeting_edit" => {
                store.edit(id, v)?;
                self.error = None;
            }
            "meeting_delete" => {
                ensure!(
                    self.recording.as_ref().map(|r| r.id) != Some(id)
                        && self.processing != Some(id),
                    "meeting is active"
                );
                store.delete(id)?;
                if self.selected == Some(id) {
                    self.selected = None;
                }
            }
            "meeting_start" => {
                ensure!(
                    available && !self.busy(),
                    "{}",
                    tr(
                        "Un autre enregistrement ou traitement est en cours.",
                        "Another recording or task is active."
                    )
                );
                ensure!(
                    speakers_installed(),
                    "{}",
                    tr(
                        "Installez les modèles d’intervenants dans les réglages.",
                        "Install speaker models in Settings."
                    )
                );
                let engine = engine.context(tr(
                    "Le modèle de transcription n’est pas prêt.",
                    "The transcription model is not ready.",
                ))?;
                let count = v["speakers"].as_u64().unwrap_or(0) as usize;
                let dir = store.1.join(id.to_string());
                std::fs::create_dir_all(&dir)?;
                store.start(id, prefs, count, &dir.join("audio.wav").to_string_lossy())?;
                let external = v["source"].as_str() == Some("microphone_system");
                store.0.execute(
                    "UPDATE meeting SET source=?2 WHERE id=?1",
                    params![
                        id,
                        if external {
                            "microphone_system"
                        } else {
                            "microphone"
                        }
                    ],
                )?;
                if external {
                    // The Swift bridge has prepared both capture sources before committing this session.
                    crate::meeting_audio::begin(id);
                } else {
                    audio::init();
                    audio::start_fresh();
                }
                self.recording = Some(Recording {
                    external,
                    id,
                    started: Instant::now(),
                    offset: 0,
                    preview_busy: false,
                    engine,
                    prefs: prefs.clone(),
                    count,
                });
                self.selected = Some(id);
                self.elapsed = 0;
                self.error = None;
            }
            "meeting_capture_failed" => {
                if self
                    .recording
                    .as_ref()
                    .is_some_and(|r| r.id == id && r.external)
                {
                    self.stop(v["error"].as_str().unwrap_or("Audio capture failed"))?;
                }
            }
            "meeting_stop" => {
                if self.recording.as_ref().map(|r| r.id) == Some(id) {
                    self.stop("")?;
                }
            }
            "meeting_retry" => {
                ensure!(available && !self.busy(), "another task is active");
                ensure!(speakers_installed(), "speaker models missing");
                let meeting = self
                    .items
                    .iter()
                    .find(|m| m.id == id)
                    .context("meeting not found")?
                    .clone();
                ensure!(
                    matches!(meeting.status.as_str(), "failed" | "interrupted" | "ready"),
                    "meeting cannot be processed"
                );
                let engine = engine.context("transcription model not ready")?;
                let mut prefs = prefs.clone();
                prefs.language = meeting.language;
                store.status(id, "processing", "")?;
                self.processing = Some(id);
                self.error = None;
                self.spawn_final(id, None, engine, prefs, meeting.speaker_count);
            }
            _ => anyhow::bail!("unknown meeting command"),
        }
        Ok(())
    }
    fn stop(&mut self, warning: &str) -> Result<()> {
        let Some(r) = self.recording.take() else {
            return Ok(());
        };
        let mut samples = if r.external {
            crate::meeting_audio::finish(r.id)
        } else {
            audio::finish(Duration::ZERO)
        };
        samples.truncate(SAMPLE_RATE as usize * 3600);
        self.processing = Some(r.id);
        // Even if SQLite temporarily fails, save the captured audio on the worker.
        let status = self
            .store
            .as_ref()
            .context("meeting storage unavailable")?
            .status(r.id, "processing", warning);
        self.spawn_final(r.id, Some(samples), r.engine, r.prefs, r.count);
        status
    }
    fn spawn_final(
        &self,
        id: i64,
        samples: Option<Vec<f32>>,
        engine: Arc<Engine>,
        mut prefs: Prefs,
        count: usize,
    ) {
        let tx = self.tx.clone();
        let diarizer = self.diarizer.clone();
        let dir = self.store.as_ref().unwrap().1.join(id.to_string());
        std::thread::spawn(move || {
            let mut seconds = 0.;
            let result = (|| {
                let path = dir.join("audio.wav");
                let samples = match samples {
                    Some(samples) => {
                        let temp = path.with_extension("tmp.wav");
                        audio::save_wav(&temp, &samples)?;
                        std::fs::rename(temp, &path)?;
                        samples
                    }
                    None if path.is_file() => audio::load_wav(&path)?,
                    None => {
                        let samples = recover_chunks(&dir)?;
                        let temp = path.with_extension("tmp.wav");
                        audio::save_wav(&temp, &samples)?;
                        std::fs::rename(temp, &path)?;
                        samples
                    }
                };
                seconds = samples.len() as f32 / SAMPLE_RATE as f32;
                // Accuracy mode is always used for the final meeting transcript.
                prefs.fast_transcription = false;
                let mut slot = diarizer
                    .lock()
                    .map_err(|_| anyhow::anyhow!("speaker engine unavailable"))?;
                if slot.is_none() {
                    *slot = Some(Diarizer::load(&engine::install_dir())?);
                }
                slot.as_ref()
                    .unwrap()
                    .analyze(&samples, &engine, &prefs, count)
            })();
            let _ = tx.send(Event::Finished {
                id,
                seconds,
                result,
            });
            crate::core::wake();
        });
    }
    pub fn tick(&mut self) -> bool {
        let mut changed = false;
        while let Ok(event) = self.rx.try_recv() {
            changed = true;
            let result = (|| -> Result<()> {
                let store = self.store.as_ref().context("meeting storage unavailable")?;
                match event {
                    Event::Preview { id, end, result } => {
                        if let Some(r) = self.recording.as_mut().filter(|r| r.id == id) {
                            r.preview_busy = false;
                            let start = r.offset;
                            r.offset = end;
                            match result {
                                Ok(text) => {
                                    let mut turns = self
                                        .items
                                        .iter()
                                        .find(|m| m.id == id)
                                        .map(|m| m.turns.clone())
                                        .unwrap_or_default();
                                    if !text.is_empty() {
                                        turns.push(Turn {
                                            start: start as f32 / SAMPLE_RATE as f32,
                                            end: end as f32 / SAMPLE_RATE as f32,
                                            speaker: 0,
                                            text,
                                            overlap: false,
                                        });
                                    }
                                    store.transcript(
                                        id,
                                        &turns,
                                        end as f32 / SAMPLE_RATE as f32,
                                        false,
                                    )?;
                                }
                                Err(e) => {
                                    self.error = Some(format!(
                                        "{} : {e}",
                                        tr(
                                            "Aperçu indisponible ; la transcription sera reprise à la fin",
                                            "Preview unavailable; transcription will run again at the end"
                                        )
                                    ))
                                }
                            }
                        }
                    }
                    Event::Finished {
                        id,
                        seconds,
                        result,
                    } => {
                        if self.processing == Some(id) {
                            self.processing = None;
                        }
                        match result {
                            Ok(turns) => store.transcript(id, &turns, seconds, true)?,
                            Err(e) => {
                                let previous = self
                                    .items
                                    .iter()
                                    .find(|m| m.id == id)
                                    .map(|m| m.error.as_str())
                                    .unwrap_or("");
                                let message = if previous.is_empty() {
                                    e.to_string()
                                } else {
                                    format!("{previous} — {e}")
                                };
                                store.status(id, "failed", &message)?;
                            }
                        }
                    }
                }
                Ok(())
            })();
            if let Err(e) = result {
                self.error = Some(e.to_string());
            }
            self.refresh();
        }
        if let Some(r) = self.recording.as_mut() {
            let elapsed = r.started.elapsed().as_secs();
            if self.elapsed != elapsed {
                self.elapsed = elapsed;
                changed = true;
            }
            let error = if r.external {
                None
            } else {
                audio::take_error()
            };
            if error.is_some() || elapsed >= 3600 {
                if let Err(e) = self.stop(error.as_deref().unwrap_or("")) {
                    self.error = Some(e.to_string());
                }
                self.refresh();
                return true;
            }
            if !r.preview_busy {
                let size = SAMPLE_RATE as usize * 5;
                if let Some(samples) = if r.external {
                    crate::meeting_audio::chunk(r.id, r.offset, size)
                } else {
                    audio::recording_chunk(r.offset, size)
                } {
                    r.preview_busy = true;
                    let id = r.id;
                    let start = r.offset;
                    let end = start + samples.len();
                    let engine = r.engine.clone();
                    let prefs = r.prefs.clone();
                    let tx = self.tx.clone();
                    let dir = self.store.as_ref().unwrap().1.join(id.to_string());
                    std::thread::spawn(move || {
                        let result = (|| {
                            // Durable checkpoints also allow retry after an app crash.
                            let path = dir.join(format!("chunk-{start:010}.wav"));
                            let temp = path.with_extension("tmp");
                            audio::save_wav(&temp, &samples)?;
                            std::fs::rename(temp, path)?;
                            let prompt = engine::build_prompt(&prefs.dictionary, &prefs.language);
                            Ok(engine
                                .transcribe_with_options(&samples, &prefs.language, &prompt, true)?
                                .text)
                        })();
                        let _ = tx.send(Event::Preview { id, end, result });
                        crate::core::wake();
                    });
                }
            }
        }
        changed
    }
}
fn speakers_installed() -> bool {
    crate::speakers::installed()
}
fn recover_chunks(dir: &std::path::Path) -> Result<Vec<f32>> {
    let mut paths = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension().is_some_and(|e| e == "wav")
                && p.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with("chunk-"))
        })
        .collect::<Vec<_>>();
    paths.sort();
    let mut samples = Vec::new();
    for path in paths {
        let offset = path
            .file_stem()
            .and_then(|s| s.to_str())
            .and_then(|s| s.strip_prefix("chunk-"))
            .and_then(|s| s.parse::<usize>().ok())
            .context("invalid audio checkpoint")?;
        ensure!(
            offset == samples.len(),
            "missing audio checkpoint; refusing to shift timestamps"
        );
        samples.extend(audio::load_wav(&path)?);
        ensure!(
            samples.len() <= SAMPLE_RATE as usize * 3600,
            "audio checkpoint exceeds one hour"
        );
    }
    ensure!(
        !samples.is_empty(),
        "{}",
        tr(
            "Aucun audio sauvegardé à reprendre.",
            "No saved audio to recover."
        )
    );
    Ok(samples)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn notes_and_names_survive_worker_updates() {
        let store = Store::init(
            Connection::open_in_memory().unwrap(),
            PathBuf::from("/nonexistent/diktation-test"),
        )
        .unwrap();
        let id = store.create().unwrap();
        store
            .start(id, &Prefs::default(), 2, "fixture.wav")
            .unwrap();
        store
            .edit(
                id,
                &json!({"notes":"Décision à vérifier", "title":"Équipe", "names":{"1":"Marie"}}),
            )
            .unwrap();
        let turn = Turn {
            start: 0.,
            end: 2.,
            speaker: 1,
            text: "Bonjour".into(),
            overlap: false,
        };
        store.status(id, "processing", "").unwrap();
        store.transcript(id, &[turn], 2., true).unwrap();
        // A late provisional result must not overwrite the final transcript.
        store.transcript(id, &[], 15., false).unwrap();
        let m = &store.list().unwrap()[0];
        assert_eq!(m.notes, "Décision à vérifier");
        assert_eq!(m.names["1"], "Marie");
        assert_eq!(m.turns.len(), 1);
        assert_eq!(m.status, "ready");
    }
    #[test]
    fn interrupted_sessions_recover_and_ids_are_never_reused() {
        let store = Store::init(
            Connection::open_in_memory().unwrap(),
            PathBuf::from("/nonexistent/diktation-test"),
        )
        .unwrap();
        let id = store.create().unwrap();
        store.start(id, &Prefs::default(), 0, "test.wav").unwrap();
        store.edit(id, &json!({"notes":"saved"})).unwrap();
        let reopened = Store::init(store.0, store.1).unwrap();
        assert_eq!(reopened.list().unwrap()[0].status, "interrupted");
        assert_eq!(reopened.list().unwrap()[0].notes, "saved");
        reopened
            .0
            .execute("DELETE FROM meeting WHERE id=?1", [id])
            .unwrap();
        let next = reopened.create().unwrap();
        assert!(next > id);
        reopened.transcript(id, &[], 2., true).unwrap();
        assert_eq!(reopened.list().unwrap()[0].status, "draft");
    }
    #[test]
    fn recovery_preserves_checkpoint_timing() {
        let dir =
            std::env::temp_dir().join(format!("diktation-checkpoints-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        audio::save_wav(&dir.join("chunk-0000000000.wav"), &vec![0.1; 16000]).unwrap();
        audio::save_wav(&dir.join("chunk-0000016000.wav"), &vec![0.2; 16000]).unwrap();
        let samples = recover_chunks(&dir).unwrap();
        assert_eq!(samples.len(), 32000);
        assert!((samples[16000] - 0.2).abs() < 0.001);
        std::fs::rename(
            dir.join("chunk-0000016000.wav"),
            dir.join("chunk-0000032000.wav"),
        )
        .unwrap();
        assert!(recover_chunks(&dir).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    #[ignore = "requires installed Parakeet/speaker models and DIKTATION_MEETING_FIXTURE WAV"]
    fn real_meeting_pipeline_preserves_notes() {
        let fixture =
            std::env::var("DIKTATION_MEETING_FIXTURE").expect("public two-speaker WAV fixture");
        let root =
            std::env::temp_dir().join(format!("diktation-meeting-pipeline-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let db = root.join("test.sqlite");
        let store = Store::init(Connection::open(&db).unwrap(), root.join("audio")).unwrap();
        let id = store.create().unwrap();
        let dir = store.1.join(id.to_string());
        std::fs::create_dir_all(&dir).unwrap();
        let prefs = Prefs {
            language: "en".into(),
            model: "nemo-parakeet-tdt-0.6b-v3-int8".into(),
            ..Prefs::default()
        };
        store
            .start(id, &prefs, 2, &dir.join("audio.wav").to_string_lossy())
            .unwrap();
        store.status(id, "processing", "").unwrap();
        let model = engine::resolve_model(&prefs.model).unwrap();
        let engine = Arc::new(Engine::load(&model).unwrap());
        let samples = audio::load_wav(std::path::Path::new(&fixture)).unwrap();
        let mut c = Controller::with_store(Ok(store));
        c.processing = Some(id);
        c.spawn_final(id, Some(samples), engine.clone(), prefs.clone(), 2);
        c.command(&json!({"cmd":"meeting_edit","id":id,"title":"Entretien","notes":"Note saisie pendant le traitement","names":{"1":"Alice","2":"Bob"}}),None,&prefs,false);
        let started = Instant::now();
        while c.busy() {
            assert!(
                started.elapsed() < Duration::from_secs(90),
                "meeting timed out"
            );
            c.tick();
            std::thread::sleep(Duration::from_millis(10));
        }
        let m = &c.items[0];
        assert_eq!(m.status, "ready", "{}", m.error);
        assert_eq!(m.turns.len(), 4);
        assert_eq!(
            m.turns
                .iter()
                .map(|t| t.speaker)
                .collect::<std::collections::BTreeSet<_>>()
                .len(),
            2
        );
        assert_eq!(m.notes, "Note saisie pendant le traitement");
        assert!(dir.join("audio.wav").is_file());
        // Exercise the video-call backend using two timestamped synthetic sources.
        // First voice is the microphone, second voice is Mac audio; no real device is opened.
        c.command(&json!({"cmd":"meeting_create"}), None, &prefs, true);
        let call_id = c.selected.unwrap();
        c.command(
            &json!({"cmd":"meeting_start","id":call_id,"speakers":2,"source":"microphone_system"}),
            Some(engine),
            &prefs,
            true,
        );
        assert!(c.recording());
        let samples = audio::load_wav(std::path::Path::new(&fixture)).unwrap();
        for (packet, chunk) in samples.chunks(16000).enumerate() {
            let offset = packet * 16000;
            let mic: Vec<f32> = chunk
                .iter()
                .enumerate()
                .map(|(i, x)| if offset + i < 128000 { *x } else { 0. })
                .collect();
            let system: Vec<f32> = chunk
                .iter()
                .enumerate()
                .map(|(i, x)| if offset + i >= 128000 { *x } else { 0. })
                .collect();
            assert!(crate::meeting_audio::push(call_id, 0, offset, &mic));
            assert!(crate::meeting_audio::push(call_id, 1, offset, &system));
        }
        c.command(
            &json!({"cmd":"meeting_stop","id":call_id}),
            None,
            &prefs,
            true,
        );
        let started = Instant::now();
        while c.busy() {
            assert!(started.elapsed() < Duration::from_secs(90));
            c.tick();
            std::thread::sleep(Duration::from_millis(10));
        }
        let call = &c.items[0];
        assert_eq!(call.status, "ready", "{}", call.error);
        assert_eq!(call.source, "microphone_system");
        assert_eq!(call.turns.len(), 4);
        assert_eq!(
            call.turns
                .iter()
                .map(|t| t.speaker)
                .collect::<std::collections::BTreeSet<_>>()
                .len(),
            2
        );
        assert!(!crate::meeting_audio::push(call_id, 0, 0, &[1.]));
        drop(c);
        let reopened = Store::init(Connection::open(db).unwrap(), root.join("audio")).unwrap();
        let records = reopened.list_selected(Some(id), None).unwrap();
        let m = records.iter().find(|m| m.id == id).unwrap();
        assert_eq!(m.names["1"], "Alice");
        assert_eq!(m.title, "Entretien");
        assert_eq!(m.status, "ready");
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn selecting_an_archive_loads_its_notes_without_losing_active_preview() {
        let store = Store::init(
            Connection::open_in_memory().unwrap(),
            PathBuf::from("/nonexistent/test"),
        )
        .unwrap();
        let first = store.create().unwrap();
        store
            .edit(first, &json!({"notes":"archived notes"}))
            .unwrap();
        let second = store.create().unwrap();
        let initial = store.list_selected(None, None).unwrap();
        assert!(!initial[1].detail_loaded);
        assert!(initial[1].notes.is_empty());
        let selected = store.list_selected(Some(first), Some(second)).unwrap();
        assert!(selected.iter().all(|m| m.detail_loaded));
        assert_eq!(selected[1].notes, "archived notes");
    }
}
