//! Raccourci global fait de modificateurs seuls (Fn, ⌃, ⌥, ⌘, ⇧, ⌥ droite…),
//! lu par un `CGEventTap` sur son propre fil (permission Accessibilité).
//!
//! Gestes :
//! - maintenir la combinaison → dictée, relâcher → transcription et collage ;
//! - deux appuis brefs → mains libres (un nouvel appui arrête) ;
//! - une autre touche pendant l'appui → c'était un raccourci clavier, la
//!   dictée est abandonnée sans bruit ;
//! - Échap pendant l'enregistrement → annulation (la touche est avalée) ;
//! - ⌃⌘V → recoller la dernière transcription (avalée aussi).
//!
//! Une seconde combinaison (fn + ⌃ par défaut) lance le mode commande, avec
//! les mêmes gestes sauf les mains libres. Si elle contient celle de la
//! dictée, l'appui commence comme une dictée puis bascule (`CommandUpgrade`).
//!
//! Les événements sont posés dans une file que l'interface relève à chaque
//! tour (`drain`).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use core_foundation::base::TCFType;
use core_foundation::runloop::{CFRunLoop, kCFRunLoopCommonModes};
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
    CGEventType, CallbackResult, EventField,
};
use serde::{Deserialize, Serialize};

/// Touche modificatrice utilisable dans la combinaison.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Key {
    Fn,
    Control,
    Option,
    Command,
    Shift,
    RightOption,
    RightCommand,
}

impl Key {
    pub fn label(self) -> &'static str {
        match self {
            Key::Fn => "fn",
            Key::Control => "⌃",
            Key::Option => "⌥",
            Key::Command => "⌘",
            Key::Shift => "⇧",
            Key::RightOption => crate::i18n::tr("⌥ droite", "right ⌥"),
            Key::RightCommand => crate::i18n::tr("⌘ droite", "right ⌘"),
        }
    }
}

// Bits dépendants du côté (IOLLEvent.h).
const RIGHT_CMD: u64 = 0x10;
const RIGHT_ALT: u64 = 0x40;
const LEFT_CMD: u64 = 0x08;
const LEFT_ALT: u64 = 0x20;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chord {
    pub keys: Vec<Key>,
}

impl Default for Chord {
    fn default() -> Self {
        Self { keys: vec![Key::Fn] }
    }
}

impl Chord {
    pub fn label(&self) -> String {
        if self.keys.is_empty() {
            return "—".into();
        }
        self.keys.iter().map(|k| k.label()).collect::<Vec<_>>().join(" + ")
    }

    /// La combinaison est tenue, et rien d'autre parmi les modificateurs.
    fn matches(&self, flags: u64) -> bool {
        if self.keys.is_empty() {
            return false;
        }
        let f = |m: CGEventFlags| flags & m.bits() != 0;
        let fn_down = f(CGEventFlags::CGEventFlagSecondaryFn);
        let ctrl = f(CGEventFlags::CGEventFlagControl);
        let shift = f(CGEventFlags::CGEventFlagShift);
        let alt = f(CGEventFlags::CGEventFlagAlternate);
        let cmd = f(CGEventFlags::CGEventFlagCommand);
        let r_alt = alt && flags & RIGHT_ALT != 0;
        let l_alt = alt && flags & LEFT_ALT != 0;
        let r_cmd = cmd && flags & RIGHT_CMD != 0;
        let l_cmd = cmd && flags & LEFT_CMD != 0;
        let has = |k: Key| self.keys.contains(&k);

        let want_alt = has(Key::Option);
        let want_cmd = has(Key::Command);
        let alt_ok = if has(Key::RightOption) && !want_alt {
            r_alt && !l_alt
        } else {
            alt == (want_alt || has(Key::RightOption))
        };
        let cmd_ok = if has(Key::RightCommand) && !want_cmd {
            r_cmd && !l_cmd
        } else {
            cmd == (want_cmd || has(Key::RightCommand))
        };
        fn_down == has(Key::Fn) && ctrl == has(Key::Control) && shift == has(Key::Shift) && alt_ok && cmd_ok
    }
}

/// Modificateurs tenus, pour l'enregistreur de raccourci des Réglages.
pub fn keys_from_flags(flags: u64) -> Vec<Key> {
    let f = |m: CGEventFlags| flags & m.bits() != 0;
    let mut keys = Vec::new();
    if f(CGEventFlags::CGEventFlagSecondaryFn) {
        keys.push(Key::Fn);
    }
    if f(CGEventFlags::CGEventFlagControl) {
        keys.push(Key::Control);
    }
    if f(CGEventFlags::CGEventFlagAlternate) {
        let l = flags & LEFT_ALT != 0;
        let r = flags & RIGHT_ALT != 0;
        keys.push(if r && !l { Key::RightOption } else { Key::Option });
    }
    if f(CGEventFlags::CGEventFlagCommand) {
        let l = flags & LEFT_CMD != 0;
        let r = flags & RIGHT_CMD != 0;
        keys.push(if r && !l { Key::RightCommand } else { Key::Command });
    }
    if f(CGEventFlags::CGEventFlagShift) {
        keys.push(Key::Shift);
    }
    keys
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// Combinaison enfoncée : commencer à écouter.
    Press,
    /// Relâchée après un appui long : transcrire.
    Release,
    /// Appui bref ou combinaison détournée : abandonner sans bruit.
    Abort,
    /// Double appui : mains libres.
    HandsFree,
    /// Échap pendant l'écoute.
    Cancel,
    /// ⌃⌘V.
    PasteLast,
    /// Enregistreur de raccourci : nouveaux modificateurs relâchés.
    Recorded(u64),
    /// Combinaison du mode commande enfoncée.
    CommandPress,
    /// La combinaison de dictée tout juste enfoncée devient celle du mode
    /// commande (fn, puis fn + ⌃) : l'écoute en cours passe en commande.
    CommandUpgrade,
    /// Combinaison du mode commande relâchée après un appui long.
    CommandRelease,
    /// Appui bref ou détourné sur la combinaison du mode commande.
    CommandAbort,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Dictation,
    Command,
}

const TAP_MAX: Duration = Duration::from_millis(250);
const DOUBLE_TAP: Duration = Duration::from_millis(450);
const KEY_ESCAPE: i64 = 53;
const KEY_V: i64 = 9;

struct State {
    chord: Chord,
    /// Combinaison tenue en ce moment.
    active: Option<Kind>,
    /// Une combinaison vient de finir alors que des touches restent
    /// tenues (⌃ lâché avant fn) : rien ne démarre avant de tout relâcher.
    blocked: bool,
    pressed_at: Instant,
    hijacked: bool,
    last_tap: Option<Instant>,
    /// Enregistreur : plus grande combinaison vue pendant l'appui.
    record_peak: u64,
}

static QUEUE: Mutex<VecDeque<Event>> = Mutex::new(VecDeque::new());
static STATE: Mutex<Option<State>> = Mutex::new(None);
/// Combinaison du mode commande (`None` : désactivé).
static COMMAND: Mutex<Option<Chord>> = Mutex::new(None);
/// L'interface écoute (Échap est alors avalé).
pub static LISTENING: AtomicBool = AtomicBool::new(false);
/// L'enregistreur de raccourci des Réglages est ouvert.
pub static RECORDING_CHORD: AtomicBool = AtomicBool::new(false);
static TAP_PORT: AtomicPtr<std::ffi::c_void> = AtomicPtr::new(std::ptr::null_mut());
pub static TAP_OK: AtomicBool = AtomicBool::new(false);

fn push(e: Event) {
    QUEUE.lock().unwrap().push_back(e);
    crate::core::wake();
}

pub fn drain() -> Vec<Event> {
    QUEUE.lock().unwrap().drain(..).collect()
}

pub fn set_chord(chord: Chord) {
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        s.chord = chord;
        s.active = None;
    }
}

/// Un appui en cours se termine normalement au prochain changement de
/// modificateurs.
pub fn set_command_chord(chord: Option<Chord>) {
    *COMMAND.lock().unwrap() = chord;
}

/// Lance le fil du `CGEventTap`. Renvoie faux si le tap n'a pas pu être créé
/// (Accessibilité refusée) ; `start` peut être rappelé plus tard.
pub fn start(chord: Chord) {
    *STATE.lock().unwrap() = Some(State {
        chord,
        active: None,
        blocked: false,
        pressed_at: Instant::now(),
        hijacked: false,
        last_tap: None,
        record_peak: 0,
    });
    if TAP_OK.load(Ordering::SeqCst) {
        return;
    }
    std::thread::Builder::new()
        .name("diktation-hotkey".into())
        .spawn(|| {
            let tap = CGEventTap::new(
                CGEventTapLocation::Session,
                CGEventTapPlacement::HeadInsertEventTap,
                CGEventTapOptions::Default,
                vec![CGEventType::FlagsChanged, CGEventType::KeyDown],
                callback,
            );
            let Ok(tap) = tap else {
                eprintln!("diktation: CGEventTap refusé (Accessibilité ?)");
                return;
            };
            TAP_PORT.store(tap.mach_port().as_concrete_TypeRef() as *mut _, Ordering::SeqCst);
            let source = tap.mach_port().create_runloop_source(0).expect("runloop source");
            CFRunLoop::get_current().add_source(&source, unsafe { kCFRunLoopCommonModes });
            tap.enable();
            TAP_OK.store(true, Ordering::SeqCst);
            CFRunLoop::run_current();
            TAP_OK.store(false, Ordering::SeqCst);
        })
        .expect("fil hotkey");
}

unsafe extern "C" {
    fn CGEventTapEnable(tap: *mut std::ffi::c_void, enable: bool);
}

fn callback(_proxy: *const std::ffi::c_void, ty: CGEventType, event: &CGEvent) -> CallbackResult {
    match ty {
        CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput => {
            let port = TAP_PORT.load(Ordering::SeqCst);
            if !port.is_null() {
                unsafe { CGEventTapEnable(port, true) };
            }
            CallbackResult::Keep
        }
        CGEventType::FlagsChanged => {
            on_flags(event.get_flags().bits());
            CallbackResult::Keep
        }
        CGEventType::KeyDown => on_key(event),
        _ => CallbackResult::Keep,
    }
}

fn on_flags(flags: u64) {
    let mut guard = STATE.lock().unwrap();
    let Some(s) = guard.as_mut() else { return };

    if RECORDING_CHORD.load(Ordering::SeqCst) {
        let keys = keys_from_flags(flags);
        if keys.is_empty() {
            if s.record_peak != 0 {
                push(Event::Recorded(s.record_peak));
                s.record_peak = 0;
            }
        } else if keys.len() >= keys_from_flags(s.record_peak).len() {
            s.record_peak = flags;
        }
        return;
    }

    let which = if s.chord.matches(flags) {
        Some(Kind::Dictation)
    } else if COMMAND.lock().unwrap().as_ref().is_some_and(|c| c.matches(flags)) {
        Some(Kind::Command)
    } else {
        None
    };
    let any_down = !keys_from_flags(flags).is_empty();
    if which == s.active {
        if !any_down {
            s.blocked = false;
        }
        return;
    }

    // fn puis ⌃ : l'appui sur fn n'était que le début de fn + ⌃.
    let upgrade = s.active == Some(Kind::Dictation)
        && which == Some(Kind::Command)
        && !s.hijacked
        && s.pressed_at.elapsed() < TAP_MAX;
    if upgrade {
        s.active = Some(Kind::Command);
        s.last_tap = None;
        push(Event::CommandUpgrade);
        return;
    }

    if let Some(kind) = s.active.take() {
        end(s, kind);
        if any_down {
            s.blocked = true;
        }
    }
    if !any_down {
        s.blocked = false;
    }
    let Some(kind) = which else { return };
    if s.blocked {
        return;
    }
    s.active = Some(kind);
    s.pressed_at = Instant::now();
    s.hijacked = false;
    if !LISTENING.load(Ordering::SeqCst) {
        // Relancer le micro tout de suite, sans attendre le tour de
        // l'interface (jusqu'à 33 ms).
        crate::audio::arm();
    }
    push(match kind {
        Kind::Dictation => Event::Press,
        Kind::Command => Event::CommandPress,
    });
}

/// Fin d'un appui sur la combinaison `kind`.
fn end(s: &mut State, kind: Kind) {
    if s.hijacked {
        return;
    }
    let held = s.pressed_at.elapsed();
    match kind {
        Kind::Command => push(if held < TAP_MAX { Event::CommandAbort } else { Event::CommandRelease }),
        Kind::Dictation if held < TAP_MAX => {
            let double = s.last_tap.is_some_and(|t| t.elapsed() < DOUBLE_TAP);
            if double {
                s.last_tap = None;
                push(Event::HandsFree);
            } else {
                s.last_tap = Some(Instant::now());
                push(Event::Abort);
            }
        }
        Kind::Dictation => {
            s.last_tap = None;
            push(Event::Release);
        }
    }
}

fn on_key(event: &CGEvent) -> CallbackResult {
    let code = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE);
    let flags = event.get_flags();
    if code == KEY_ESCAPE && LISTENING.load(Ordering::SeqCst) {
        push(Event::Cancel);
        return CallbackResult::Drop;
    }
    let ctrl_cmd = CGEventFlags::CGEventFlagControl | CGEventFlags::CGEventFlagCommand;
    if code == KEY_V && flags.contains(ctrl_cmd) && !flags.contains(CGEventFlags::CGEventFlagAlternate) {
        push(Event::PasteLast);
        return CallbackResult::Drop;
    }
    let mut guard = STATE.lock().unwrap();
    if let Some(s) = guard.as_mut()
        && let Some(kind) = s.active
        && !s.hijacked
    {
        // Une vraie touche pendant la combinaison : c'est un raccourci
        // clavier (⌘C, fn+F1…), pas une dictée.
        s.hijacked = true;
        s.last_tap = None;
        push(match kind {
            Kind::Dictation => Event::Abort,
            Kind::Command => Event::CommandAbort,
        });
    }
    CallbackResult::Keep
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chord_matching() {
        let fn_only = Chord { keys: vec![Key::Fn] };
        assert!(fn_only.matches(0x800000));
        assert!(!fn_only.matches(0x800000 | 0x100000));
        let r_opt = Chord { keys: vec![Key::RightOption] };
        assert!(r_opt.matches(0x80000 | RIGHT_ALT));
        assert!(!r_opt.matches(0x80000 | LEFT_ALT));
    }
}
