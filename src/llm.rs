//! Modèle de langage local : celui d'Apple Intelligence (framework
//! FoundationModels), joint par le petit outil Swift `diktation-llm`
//! (`llm/main.swift`, installé à côté du binaire dans `Diktation.app`).
//!
//! L'outil n'est lancé que si la reformulation ou le mode commande est
//! activé, puis reste ouvert : le modèle est géré par macOS, en dehors de la
//! mémoire de Diktation. Une ligne JSON par message (voir `llm/main.swift`).
//! Une requête qui dépasse son délai tue l'outil, relancé à la suivante.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    /// Pas encore interrogé (ou outil arrêté).
    Unknown,
    Ready,
    Unavailable(String),
}

struct Helper {
    child: Child,
    stdin: ChildStdin,
    rx: Receiver<Value>,
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub struct Llm {
    helper: Mutex<Option<Helper>>,
    status: Mutex<Status>,
    next_id: AtomicU64,
}

/// `Contents/MacOS/diktation-llm` dans l'app, `target/diktation-llm` en
/// développement.
fn helper_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    [dir.join("diktation-llm"), dir.join("../diktation-llm")].into_iter().find(|p| p.is_file())
}

impl Llm {
    pub fn new() -> Self {
        Self { helper: Mutex::new(None), status: Mutex::new(Status::Unknown), next_id: AtomicU64::new(1) }
    }

    pub fn status(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    pub fn is_ready(&self) -> bool {
        self.status() == Status::Ready
    }

    fn set_status(&self, s: Status) {
        *self.status.lock().unwrap() = s;
    }

    /// Lance l'outil et vérifie que le modèle est disponible. Bloquant
    /// (quelques ms) : hors du fil principal.
    pub fn start(&self) {
        let mut slot = self.helper.lock().unwrap();
        match self.ensure(&mut slot, Duration::from_secs(5)) {
            // Charge le modèle tout de suite : la première dictée ne paie
            // pas son chargement.
            Ok(()) => {
                if let Some(h) = slot.as_mut() {
                    let _ = send(h, &json!({"op": "prewarm", "instructions": ""}));
                }
            }
            Err(e) => eprintln!("diktation: modèle de langage : {e}"),
        }
    }

    /// Arrête l'outil (fonctions désactivées).
    pub fn stop(&self) {
        *self.helper.lock().unwrap() = None;
        self.set_status(Status::Unknown);
    }

    fn ensure(&self, slot: &mut Option<Helper>, timeout: Duration) -> Result<()> {
        if let Some(h) = slot.as_mut()
            && matches!(h.child.try_wait(), Ok(None))
        {
            return Ok(());
        }
        *slot = None;
        let Some(path) = helper_path() else {
            let msg = crate::i18n::tr("outil diktation-llm introuvable", "diktation-llm helper not found").to_string();
            self.set_status(Status::Unavailable(msg.clone()));
            bail!(msg);
        };
        let mut child = match Command::new(path).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn() {
            Ok(c) => c,
            Err(e) => {
                self.set_status(Status::Unavailable(format!("outil diktation-llm : {e}")));
                bail!(e);
            }
        };
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("stdin"))?;
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("stdout"))?;
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new().name("diktation-llm".into()).spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if let Ok(v) = serde_json::from_str::<Value>(&line)
                    && tx.send(v).is_err()
                {
                    break;
                }
            }
        })?;
        let mut helper = Helper { child, stdin, rx };
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let reply = match call(&mut helper, id, json!({"id": id, "op": "status"}), timeout.min(Duration::from_secs(5))) {
            Ok(r) => r,
            Err(e) => {
                self.set_status(Status::Unavailable(format!("outil diktation-llm : {e}")));
                return Err(e);
            }
        };
        if reply["available"].as_bool() == Some(true) {
            self.set_status(Status::Ready);
            *slot = Some(helper);
            Ok(())
        } else {
            let reason = reply["reason"].as_str().unwrap_or("Apple Intelligence indisponible").to_string();
            self.set_status(Status::Unavailable(reason.clone()));
            bail!(reason)
        }
    }

    /// Prépare le modèle avec ces instructions pendant que l'utilisateur
    /// parle. Ne bloque jamais : sans effet si l'outil est occupé ou arrêté.
    pub fn prewarm(&self, instructions: &str) {
        let Ok(mut slot) = self.helper.try_lock() else { return };
        if let Some(h) = slot.as_mut() {
            let _ = send(h, &json!({"op": "prewarm", "instructions": instructions}));
        }
    }

    /// Une réponse du modèle, ou une erreur après `timeout`.
    pub fn respond(&self, instructions: &str, prompt: &str, max_tokens: usize, timeout: Duration) -> Result<String> {
        let deadline = Instant::now() + timeout;
        let mut slot = lock_until(&self.helper, deadline)?;
        self.ensure(&mut slot, deadline.saturating_duration_since(Instant::now()))?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() { bail!(crate::i18n::tr("le modèle n'a pas répondu à temps", "the model did not answer in time")); }
        let helper = slot.as_mut().expect("outil lancé");
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = json!({"id": id, "op": "respond", "instructions": instructions, "prompt": prompt, "max_tokens": max_tokens});
        match call(helper, id, req, remaining) {
            Ok(reply) => match (reply["text"].as_str(), reply["error"].as_str()) {
                (Some(text), _) => Ok(text.to_string()),
                (_, Some(err)) => bail!("{err}"),
                _ => bail!(crate::i18n::tr("réponse illisible du modèle", "unreadable model response")),
            },
            Err(e) => {
                // L'outil traite une requête à la fois : s'il ne répond plus,
                // on le relance plutôt que d'attendre derrière lui.
                *slot = None;
                Err(e)
            }
        }
    }
}

fn send(h: &mut Helper, v: &Value) -> Result<()> {
    let mut line = v.to_string();
    line.push('\n');
    h.stdin.write_all(line.as_bytes())?;
    h.stdin.flush()?;
    Ok(())
}

/// Envoie `req` et attend la réponse portant `id` (les réponses en retard
/// d'une requête précédente sont ignorées).
fn call(h: &mut Helper, id: u64, req: Value, timeout: Duration) -> Result<Value> {
    send(h, &req)?;
    let deadline = Instant::now() + timeout;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match h.rx.recv_timeout(left) {
            Ok(v) if v["id"].as_u64() == Some(id) => return Ok(v),
            Ok(_) => {}
            Err(RecvTimeoutError::Timeout) => bail!(crate::i18n::tr("le modèle n'a pas répondu à temps", "the model did not answer in time")),
            Err(RecvTimeoutError::Disconnected) => bail!(crate::i18n::tr("l'outil diktation-llm s'est arrêté", "the diktation-llm helper stopped")),
        }
    }
}

/// Queueing and helper startup belong to the same user-visible latency budget.
fn lock_until<T>(mutex: &Mutex<T>, deadline: Instant) -> Result<std::sync::MutexGuard<'_, T>> {
    loop {
        if Instant::now() >= deadline { bail!("model busy: response deadline exceeded"); }
        match mutex.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(std::sync::TryLockError::Poisoned(_)) => bail!("model worker unavailable"),
            Err(std::sync::TryLockError::WouldBlock) => {
                std::thread::sleep(Duration::from_millis(5).min(deadline.saturating_duration_since(Instant::now())));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn busy_helper_cannot_exceed_queue_deadline() {
        let mutex = Mutex::new(());
        let _held = mutex.lock().unwrap();
        assert!(lock_until(&mutex, Instant::now() + Duration::from_millis(10)).is_err());
    }
}
