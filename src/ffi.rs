//! API C du cœur, appelée par l'app Swift (`app/`, en-tête `app/diktation.h`).
//!
//! - `dk_start(cb, user)` : lance le cœur ; `cb` reçoit chaque événement en
//!   JSON (`{"type":"changed"}`, `{"type":"pill",…}`) depuis le fil du cœur.
//! - `dk_send(json)` : commande de l'interface (`{"cmd":"set_prefs",…}`).
//! - `dk_state()` : instantané JSON complet, à libérer avec `dk_free`.

use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::atomic::{AtomicBool, Ordering};

use crate::core::{self, CORE};

pub type Callback = extern "C" fn(event: *const c_char, user: *mut c_void);

static STARTED: AtomicBool = AtomicBool::new(false);

#[unsafe(no_mangle)]
pub extern "C" fn dk_start(cb: Callback, user: *mut c_void) -> bool {
    if STARTED.swap(true, Ordering::SeqCst) {
        return false;
    }
    let user = user as usize;
    core::run(move |event| {
        if let Ok(c) = CString::new(event) {
            cb(c.as_ptr(), user as *mut c_void);
        }
    });
    true
}

/// # Safety
/// `json` : chaîne C terminée par un zéro, valide pendant l'appel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dk_send(json: *const c_char) {
    if json.is_null() {
        return;
    }
    let text = unsafe { CStr::from_ptr(json) }.to_string_lossy();
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
        eprintln!("diktation: commande illisible : {text}");
        return;
    };
    if let Some(core) = CORE.lock().unwrap().as_mut() {
        core.command(&v);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dk_state() -> *mut c_char {
    let json = CORE.lock().unwrap().as_ref().map(|c| c.state_json()).unwrap_or_else(|| "{}".into());
    CString::new(json).unwrap_or_default().into_raw()
}

/// # Safety
/// `s` : pointeur rendu par `dk_state`, libéré une seule fois.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dk_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
