//! Capture du micro (cpal / CoreAudio), ramenée en 16 kHz mono f32.
//!
//! Ouvrir un flux CoreAudio coûte cher à chaque fois (200 ms à 1,5 s :
//! deux AudioUnit créées par cpal), et l'audio de ce délai est perdu. Le flux
//! est donc construit une fois, au lancement, sur un fil dédié, puis mis en
//! **pause** : CoreAudio ne fait alors plus tourner le micro et le voyant
//! orange s'éteint. Un appui le relance (~60 ms), il reste actif quelques
//! secondes après la dictée (enchaîner sans délai), puis repasse en pause.
//!
//! Tant que le flux tourne sans dictée, seules les dernières `PREROLL`
//! secondes sont gardées : elles servent de pré-écoute au début de la
//! dictée suivante, puis sont jetées.
//!
//! Le fil principal ne fait que poser des commandes et lire l'état partagé :
//! il ne bloque jamais sur CoreAudio.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, anyhow};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};

use crate::engine::SAMPLE_RATE;

/// Pré-écoute gardée quand le flux tourne sans dictée.
const PREROLL: f32 = 0.3;
/// Flux relancé par un appui sans dictée derrière : remis en pause après.
const ARM_TIMEOUT: Duration = Duration::from_secs(5);

enum Cmd {
    /// Relancer le flux : à l'appui sur le raccourci (`press`), puis au début
    /// de la dictée par sûreté.
    Arm { at: Instant, press: bool },
    /// Remettre en pause à cette échéance si aucune dictée n'a repris.
    PauseAt(Instant),
}

#[derive(Default)]
struct Buf {
    samples: Vec<f32>,
    capturing: bool,
}

struct Mic {
    tx: Mutex<Sender<Cmd>>,
    buf: Mutex<Buf>,
    level: AtomicU32,
    /// Délai entre l'appui et le premier tampon reçu, en ms (MAX : en attente).
    first_ms: AtomicU64,
    armed_at: Mutex<Instant>,
    /// Échantillons de pré-écoute présents au début de la dictée.
    preroll: AtomicU64,
    error: Mutex<Option<String>>,
    /// Le flux a signalé une erreur (micro débranché…) : le reconstruire.
    broken: AtomicBool,
}

static MIC: OnceLock<Arc<Mic>> = OnceLock::new();

/// Lance le fil micro et prépare le flux (construit puis mis en pause).
pub fn init() {
    if MIC.get().is_some() {
        return;
    }
    let (tx, rx) = mpsc::channel();
    let mic = Arc::new(Mic {
        tx: Mutex::new(tx),
        buf: Mutex::new(Buf::default()),
        level: AtomicU32::new(0),
        first_ms: AtomicU64::new(u64::MAX),
        armed_at: Mutex::new(Instant::now()),
        preroll: AtomicU64::new(0),
        error: Mutex::new(None),
        broken: AtomicBool::new(false),
    });
    let _ = MIC.set(mic.clone());
    std::thread::Builder::new().name("diktation-mic".into()).spawn(move || run(mic, rx)).expect("fil micro");
}

/// Appui sur le raccourci (fil du clavier) : relancer le flux sans attendre
/// que l'interface traite l'événement.
pub fn arm() {
    send(Cmd::Arm { at: Instant::now(), press: true });
}

fn send(cmd: Cmd) {
    if let Some(m) = MIC.get() {
        let _ = m.tx.lock().unwrap().send(cmd);
    }
}

/// Début de la dictée. Ne bloque pas : la pré-écoute déjà reçue est gardée,
/// la suite s'ajoute dès que le flux tourne.
pub fn start() {
    let Some(m) = MIC.get() else { return };
    {
        let mut b = m.buf.lock().unwrap();
        b.capturing = true;
        m.preroll.store(b.samples.len() as u64, Ordering::Relaxed);
    }
    *m.error.lock().unwrap() = None;
    send(Cmd::Arm { at: Instant::now(), press: false });
}

/// Fin de la dictée : rend l'audio. Le flux reste actif `linger`, puis
/// repasse en pause.
pub fn finish(linger: Duration) -> Vec<f32> {
    let Some(m) = MIC.get() else { return Vec::new() };
    let samples = {
        let mut b = m.buf.lock().unwrap();
        b.capturing = false;
        std::mem::take(&mut b.samples)
    };
    m.level.store(0, Ordering::Relaxed);
    send(Cmd::PauseAt(Instant::now() + linger));
    samples
}

/// Niveau récent (0..1), pour l'animation.
pub fn level() -> f32 {
    MIC.get().map_or(0.0, |m| f32::from_bits(m.level.load(Ordering::Relaxed)))
}

/// Erreur d'ouverture survenue depuis le dernier `start`.
pub fn take_error() -> Option<String> {
    MIC.get().and_then(|m| m.error.lock().unwrap().take())
}

/// Pour le journal : (ms entre l'appui et le premier son, ms de pré-écoute).
pub fn timings() -> (Option<u64>, u64) {
    let Some(m) = MIC.get() else { return (None, 0) };
    let first = m.first_ms.load(Ordering::Relaxed);
    let pre = m.preroll.load(Ordering::Relaxed) * 1000 / SAMPLE_RATE as u64;
    ((first != u64::MAX).then_some(first), pre)
}

struct Open {
    stream: cpal::Stream,
    /// Micro visé à la construction (voir `target`) : reconstruire si ça change.
    device: String,
    playing: bool,
}

/// Micro choisi dans les Réglages (nom CoreAudio) ; `None` : celui du système.
static PREFERRED: Mutex<Option<String>> = Mutex::new(None);

/// Choisit le micro. Pris en compte au prochain appui sur le raccourci.
pub fn set_preferred(name: Option<String>) {
    *PREFERRED.lock().unwrap() = name.filter(|n| !n.is_empty());
}

/// Clé du micro visé : le micro choisi, ou celui du système (dont
/// l'identifiant change quand on en sélectionne un autre dans macOS).
fn target() -> String {
    match PREFERRED.lock().unwrap().clone() {
        Some(name) => format!("name:{name}"),
        None => format!("default:{}", default_input_id()),
    }
}

/// Micros présents : (noms, nom du micro par défaut du système).
pub fn list_inputs() -> (Vec<String>, Option<String>) {
    let host = cpal::default_host();
    let mut names: Vec<String> =
        host.input_devices().map(|d| d.filter_map(|d| d.name().ok()).collect()).unwrap_or_default();
    names.dedup();
    let default = host.default_input_device().and_then(|d| d.name().ok());
    (names, default)
}

fn run(mic: Arc<Mic>, rx: Receiver<Cmd>) {
    let t = Instant::now();
    let mut open = match build(&mic) {
        Ok(o) => {
            let _ = o.stream.pause();
            eprintln!("diktation: micro préparé en {} ms (en pause)", t.elapsed().as_millis());
            Some(Open { playing: false, ..o })
        }
        Err(e) => {
            eprintln!("diktation: micro : {e}");
            None
        }
    };
    let mut pause_at: Option<Instant> = None;
    loop {
        let cmd = match pause_at {
            Some(at) => rx.recv_timeout(at.saturating_duration_since(Instant::now())),
            None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match cmd {
            Ok(Cmd::Arm { at, press }) => {
                pause_at = Some(Instant::now() + ARM_TIMEOUT);
                if open.as_ref().is_some_and(|o| o.playing) && !mic.broken.load(Ordering::SeqCst) {
                    // Déjà actif (fin de dictée récente) : le son est là tout de suite.
                    if press {
                        mic.first_ms.store(0, Ordering::Relaxed);
                    }
                    continue;
                }
                *mic.armed_at.lock().unwrap() = at;
                mic.first_ms.store(u64::MAX, Ordering::Relaxed);
                let device = target();
                let mut stale = mic.broken.load(Ordering::SeqCst) || open.as_ref().is_none_or(|o| o.device != device);
                if !stale && let Some(o) = open.as_mut() {
                    match o.stream.play() {
                        Ok(()) => o.playing = true,
                        Err(e) => {
                            // AudioUnit périmée (veille, coreaudiod relancé…) : on reconstruit.
                            eprintln!("diktation: micro : reprise impossible ({e}), reconstruction");
                            stale = true;
                        }
                    }
                }
                if stale {
                    // Premier essai raté, micro débranché ou autre micro par défaut.
                    open = None;
                    mic.broken.store(false, Ordering::SeqCst);
                    match build(&mic) {
                        Ok(o) => {
                            eprintln!("diktation: micro ouvert en {} ms", at.elapsed().as_millis());
                            open = Some(o);
                        }
                        Err(e) => {
                            eprintln!("diktation: micro : {e}");
                            *mic.error.lock().unwrap() = Some(e.to_string());
                        }
                    }
                }
            }
            Ok(Cmd::PauseAt(at)) => pause_at = Some(at),
            Err(RecvTimeoutError::Timeout) => {
                if mic.buf.lock().unwrap().capturing {
                    // Dictée longue (mains libres) : on revérifiera plus tard.
                    pause_at = Some(Instant::now() + ARM_TIMEOUT);
                    continue;
                }
                pause_at = None;
                // Sans tenir `buf` : l'arrêt attend la fin du rappel audio,
                // qui le prend.
                if let Some(o) = open.as_mut().filter(|o| o.playing) {
                    let _ = o.stream.pause();
                    o.playing = false;
                }
                let mut b = mic.buf.lock().unwrap();
                if !b.capturing {
                    b.samples.clear();
                }
                mic.level.store(0, Ordering::Relaxed);
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

/// Construit le flux sur le micro par défaut ; il démarre aussitôt.
fn build(mic: &Arc<Mic>) -> Result<Open> {
    let device_id = target();
    let host = cpal::default_host();
    let preferred = PREFERRED.lock().unwrap().clone();
    // Micro choisi s'il est branché, sinon celui du système.
    let chosen = preferred.and_then(|name| {
        host.input_devices().ok()?.find(|d| d.name().is_ok_and(|n| n == name))
    });
    let device = match chosen {
        Some(d) => d,
        None => host.default_input_device().context("aucun micro")?,
    };
    let supported = device.default_input_config().context("format du micro")?;
    let format = supported.sample_format();
    let config: StreamConfig = supported.into();
    let channels = config.channels as usize;
    let mut resampler = Resampler::new(config.sample_rate.0, SAMPLE_RATE);
    let keep = (PREROLL * SAMPLE_RATE as f32) as usize;

    let m = mic.clone();
    let mut out = Vec::new();
    let mut meter = Meter::new();
    let mut push = move |mono: &mut dyn Iterator<Item = f32>| {
        out.clear();
        let (mut sum, mut n) = (0f32, 0usize);
        for x in mono {
            sum += x * x;
            n += 1;
            resampler.push(x, &mut out);
        }
        let rms = if n > 0 { (sum / n as f32).sqrt() } else { 0.0 };
        if m.first_ms.load(Ordering::Relaxed) == u64::MAX {
            let ms = m.armed_at.try_lock().map_or(0, |t| t.elapsed().as_millis() as u64);
            m.first_ms.store(ms, Ordering::Relaxed);
        }
        let mut b = m.buf.lock().unwrap();
        b.samples.extend_from_slice(&out);
        if !b.capturing {
            let len = b.samples.len();
            if len > keep {
                b.samples.drain(..len - keep);
            }
            return;
        }
        drop(b);
        m.level.store(meter.push(rms).to_bits(), Ordering::Relaxed);
    };
    let m = mic.clone();
    let err = move |e| {
        eprintln!("diktation: micro : {e}");
        m.broken.store(true, Ordering::SeqCst);
    };

    let stream = match format {
        SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _| push(&mut data.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32)),
            err,
            None,
        )?,
        SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _| {
                push(&mut data.chunks(channels).map(|f| f.iter().map(|&x| x as f32 / 32768.0).sum::<f32>() / channels as f32))
            },
            err,
            None,
        )?,
        SampleFormat::I32 => device.build_input_stream(
            &config,
            move |data: &[i32], _| {
                push(&mut data.chunks(channels).map(|f| f.iter().map(|&x| x as f32 / 2147483648.0).sum::<f32>() / channels as f32))
            },
            err,
            None,
        )?,
        other => return Err(anyhow!("format micro non géré : {other:?}")),
    };
    stream.play()?;
    Ok(Open { stream, device: device_id, playing: true })
}

/// Identifiant CoreAudio du micro par défaut (lecture quasi gratuite), pour
/// voir s'il a changé depuis la construction du flux.
fn default_input_id() -> u32 {
    #[repr(C)]
    struct Address {
        selector: u32,
        scope: u32,
        element: u32,
    }
    #[link(name = "CoreAudio", kind = "framework")]
    unsafe extern "C" {
        fn AudioObjectGetPropertyData(
            object: u32,
            address: *const Address,
            qualifier_size: u32,
            qualifier: *const std::ffi::c_void,
            size: *mut u32,
            data: *mut std::ffi::c_void,
        ) -> i32;
    }
    // kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, global.
    let address = Address { selector: u32::from_be_bytes(*b"dIn "), scope: u32::from_be_bytes(*b"glob"), element: 0 };
    let mut id = 0u32;
    let mut size = 4u32;
    unsafe { AudioObjectGetPropertyData(1, &address, 0, std::ptr::null(), &mut size, &mut id as *mut u32 as *mut _) };
    id
}

/// Niveau affiché par la pastille (0..1), en décibels et adapté au micro :
/// le bruit de fond et le plafond de la voix sont suivis en continu, si bien
/// qu'un micro qui capte bas (crêtes à 0,05 sur le micro intégré) anime
/// autant la forme d'onde qu'un micro fort. Réglé sur des dictées réelles :
/// parole ≈ 0,4 à 0,8 selon les syllabes, silence ≈ 0.
struct Meter {
    floor: f32,
    ceil: f32,
    level: f32,
}

impl Meter {
    fn new() -> Self {
        Self { floor: -60.0, ceil: -35.0, level: 0.0 }
    }

    /// `rms` d'un bloc (~10 ms) ; rend le niveau lissé.
    fn push(&mut self, rms: f32) -> f32 {
        let db = 20.0 * rms.max(1e-7).log10();
        // Bruit de fond : descend tout de suite, remonte de ~3 dB/s.
        self.floor = if db < self.floor { db } else { self.floor + 0.03 }.clamp(-80.0, -42.0);
        // Plafond : monte tout de suite, redescend lentement, au moins
        // 18 dB au-dessus du fond.
        self.ceil = if db > self.ceil { db } else { self.ceil - 0.015 }.max(self.floor + 18.0);
        let target = ((db - self.floor - 8.0) / (self.ceil - self.floor - 3.0)).clamp(0.0, 1.0).powf(1.1);
        // Montée rapide, descente assez vive pour voir les syllabes.
        self.level += (target - self.level) * if target > self.level { 0.7 } else { 0.35 };
        self.level
    }
}

/// Rééchantillonnage linéaire, suffisant pour de la voix vers 16 kHz.
struct Resampler {
    step: f64,
    pos: f64,
    prev: f32,
}

impl Resampler {
    fn new(from: u32, to: u32) -> Self {
        Self { step: from as f64 / to as f64, pos: 0.0, prev: 0.0 }
    }

    fn push(&mut self, x: f32, out: &mut Vec<f32>) {
        // `pos` = position (en échantillons d'entrée) du prochain échantillon
        // de sortie, relative à `prev`.
        while self.pos <= 1.0 {
            let t = self.pos as f32;
            out.push(self.prev + (x - self.prev) * t);
            self.pos += self.step;
        }
        self.pos -= 1.0;
        self.prev = x;
    }
}

pub fn save_wav(path: &std::path::Path, samples: &[f32]) -> Result<()> {
    let spec = hound::WavSpec { channels: 1, sample_rate: SAMPLE_RATE, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
    let mut w = hound::WavWriter::create(path, spec)?;
    for &s in samples {
        w.write_sample((s.clamp(-1.0, 1.0) * 32767.0) as i16)?;
    }
    w.finalize()?;
    Ok(())
}

pub fn load_wav(path: &std::path::Path) -> Result<Vec<f32>> {
    let mut r = hound::WavReader::open(path)?;
    let spec = r.spec();
    let ch = spec.channels as usize;
    let raw: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Int => r.samples::<i16>().map(|s| s.map(|v| v as f32 / 32768.0)).collect::<Result<_, _>>()?,
        hound::SampleFormat::Float => r.samples::<f32>().collect::<Result<_, _>>()?,
    };
    let mono: Vec<f32> = raw.chunks(ch).map(|f| f.iter().sum::<f32>() / ch as f32).collect();
    if spec.sample_rate == SAMPLE_RATE {
        return Ok(mono);
    }
    let mut rs = Resampler::new(spec.sample_rate, SAMPLE_RATE);
    let mut out = Vec::new();
    for x in mono {
        rs.push(x, &mut out);
    }
    Ok(out)
}
