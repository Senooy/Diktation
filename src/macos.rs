//! Intégration macOS : collage dans l'app active, presse-papiers,
//! permissions, sons.

#![allow(unused_unsafe)]

use std::time::Duration;

use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::CFString;
use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, CGKeyCode};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use objc2::rc::Retained;
use objc2_app_kit::{NSPasteboard, NSPasteboardItem, NSPasteboardTypeString, NSWorkspace};
use objc2_foundation::{NSArray, NSData, NSString};

// ── Permissions ─────────────────────────────────────────────────────────────

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrustedWithOptions(options: core_foundation::dictionary::CFDictionaryRef) -> bool;
    static kAXTrustedCheckOptionPrompt: core_foundation::string::CFStringRef;
}

/// Accessibilité accordée ? Avec `prompt`, macOS affiche sa demande.
pub fn accessibility_trusted(prompt: bool) -> bool {
    unsafe {
        let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
        let value = if prompt { CFBoolean::true_value() } else { CFBoolean::false_value() };
        let dict = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), value.as_CFType())]);
        AXIsProcessTrustedWithOptions(dict.as_concrete_TypeRef())
    }
}

pub fn open_privacy_pane(pane: &str) {
    let _ = std::process::Command::new("open")
        .arg(format!("x-apple.systempreferences:com.apple.preference.security?{pane}"))
        .spawn();
}

/// Réglage « Touche 🌐 : » de macOS. 0 = Ne rien faire ; sinon l'appui sur
/// fn ouvre aussi les emojis / la dictée Apple / change la source.
pub fn fn_key_usage() -> Option<i64> {
    // Lu par CFPreferences (pas de `defaults` lancé toutes les quelques
    // secondes) ; la synchronisation récupère un changement fait dans les
    // Réglages Système depuis la lecture précédente.
    unsafe {
        let app = CFString::from_static_string("com.apple.HIToolbox");
        let key = CFString::from_static_string("AppleFnUsageType");
        CFPreferencesAppSynchronize(app.as_concrete_TypeRef());
        let value = CFPreferencesCopyAppValue(key.as_concrete_TypeRef(), app.as_concrete_TypeRef());
        if value.is_null() {
            return None;
        }
        let value = core_foundation::base::CFType::wrap_under_create_rule(value);
        value.downcast::<core_foundation::number::CFNumber>().and_then(|n| n.to_i64())
    }
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFPreferencesCopyAppValue(
        key: core_foundation::string::CFStringRef,
        app: core_foundation::string::CFStringRef,
    ) -> core_foundation::base::CFTypeRef;
    fn CFPreferencesAppSynchronize(app: core_foundation::string::CFStringRef) -> bool;
}

// ── Presse-papiers et collage ───────────────────────────────────────────────

/// Contenu complet du presse-papiers (tous les types de chaque élément).
pub struct Snapshot(Vec<Vec<(Retained<NSString>, Retained<NSData>)>>);

// NSString et NSData immuables sont sûrs entre fils (Apple, « Thread Safety
// Summary ») : la restauration se fait sur un fil à part.
unsafe impl Send for Snapshot {}

pub fn snapshot() -> Snapshot {
    let mut items = Vec::new();
    unsafe {
        let pb = NSPasteboard::generalPasteboard();
        if let Some(list) = pb.pasteboardItems() {
            for item in list.iter() {
                let mut entry = Vec::new();
                for ty in item.types().iter() {
                    if let Some(data) = item.dataForType(&ty) {
                        entry.push((ty.clone(), data));
                    }
                }
                items.push(entry);
            }
        }
    }
    Snapshot(items)
}

pub fn restore(snap: Snapshot) {
    unsafe {
        let pb = NSPasteboard::generalPasteboard();
        pb.clearContents();
        if snap.0.is_empty() {
            return;
        }
        let mut objs = Vec::new();
        for entry in &snap.0 {
            let item = NSPasteboardItem::new();
            for (ty, data) in entry {
                item.setData_forType(data, ty);
            }
            objs.push(item);
        }
        let refs: Vec<&objc2::runtime::ProtocolObject<dyn objc2_app_kit::NSPasteboardWriting>> =
            objs.iter().map(|i| objc2::runtime::ProtocolObject::from_ref(&**i)).collect();
        let array = NSArray::from_slice(&refs);
        pb.writeObjects(&array);
    }
}

pub fn set_clipboard_text(text: &str) {
    unsafe {
        let pb = NSPasteboard::generalPasteboard();
        pb.clearContents();
        pb.setString_forType(&NSString::from_str(text), NSPasteboardTypeString);
    }
}

fn change_count() -> isize {
    unsafe { NSPasteboard::generalPasteboard().changeCount() }
}

const KEY_V: CGKeyCode = 9;
const KEY_C: CGKeyCode = 8;

/// Envoie ⌘V à l'app active.
pub fn press_cmd_v() {
    press_cmd(KEY_V);
}

fn press_cmd(key: CGKeyCode) {
    let Ok(src) = CGEventSource::new(CGEventSourceStateID::HIDSystemState) else { return };
    for down in [true, false] {
        if let Ok(ev) = CGEvent::new_keyboard_event(src.clone(), key, down) {
            ev.set_flags(CGEventFlags::CGEventFlagCommand);
            ev.post(CGEventTapLocation::HID);
        }
    }
}

/// Colle `text` dans l'app active en passant par le presse-papiers, puis
/// remet l'ancien contenu (si `restore_after`). Bloquant ~40 ms : à lancer
/// hors du fil principal.
pub fn paste(text: &str, restore_after: bool) {
    let saved = restore_after.then(snapshot);
    set_clipboard_text(text);
    let ours = change_count();
    std::thread::sleep(Duration::from_millis(40));
    press_cmd_v();
    if let Some(saved) = saved {
        // L'app cible lit le presse-papiers de façon asynchrone : on attend
        // avant de remettre l'ancien contenu, et seulement si personne
        // d'autre ne l'a changé entre-temps. Sur un fil à part, pour que la
        // dictée suivante puisse commencer tout de suite.
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(450));
            if change_count() == ours {
                restore(saved);
            }
        });
    }
}

/// Bundle id de l'app au premier plan (catégorie pour la reformulation).
pub fn frontmost_bundle_id() -> Option<String> {
    unsafe {
        let app = NSWorkspace::sharedWorkspace().frontmostApplication()?;
        app.bundleIdentifier().map(|n| n.to_string())
    }
}

// ── Texte sélectionné (mode commande) ───────────────────────────────────────

pub enum Selection {
    Text(String),
    /// L'app répond qu'il n'y a pas de sélection.
    Empty,
    /// L'app ne donne pas sa sélection par l'Accessibilité.
    Unknown,
}

type AXUIElementRef = *const std::ffi::c_void;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementSetAttributeValue(
        element: AXUIElementRef,
        attribute: core_foundation::string::CFStringRef,
        value: core_foundation::base::CFTypeRef,
    ) -> i32;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: core_foundation::string::CFStringRef,
        value: *mut core_foundation::base::CFTypeRef,
    ) -> i32;
    fn AXUIElementSetMessagingTimeout(element: AXUIElementRef, seconds: f32) -> i32;
    fn AXValueGetValue(value: core_foundation::base::CFTypeRef, kind: u32, out: *mut std::ffi::c_void) -> bool;
}

/// `kAXValueTypeCFRange`.
const AX_VALUE_CF_RANGE: u32 = 4;

/// Attribut AX de `element` (référence possédée), ou `None`.
unsafe fn ax_copy(element: AXUIElementRef, name: &str) -> Option<core_foundation::base::CFType> {
    let attr = CFString::new(name);
    let mut value: core_foundation::base::CFTypeRef = std::ptr::null();
    let err = unsafe { AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value) };
    (err == 0 && !value.is_null()).then(|| unsafe { core_foundation::base::CFType::wrap_under_create_rule(value) })
}

fn frontmost_pid() -> Option<i32> {
    unsafe { Some(NSWorkspace::sharedWorkspace().frontmostApplication()?.processIdentifier()) }
}

/// Élément AX de l'app au premier plan, avec un délai de réponse court.
fn frontmost_ax_app(timeout: f32) -> Option<core_foundation::base::CFType> {
    unsafe {
        let el = AXUIElementCreateApplication(frontmost_pid()?);
        if el.is_null() {
            return None;
        }
        let el = core_foundation::base::CFType::wrap_under_create_rule(el as _);
        AXUIElementSetMessagingTimeout(el.as_CFTypeRef() as _, timeout);
        Some(el)
    }
}

/// Navigateurs Chromium : leur arbre d'Accessibilité ne s'ouvre qu'avec
/// `AXEnhancedUserInterface` (le drapeau que pose VoiceOver).
const CHROMIUM: &[&str] = &[
    "com.google.Chrome",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "company.thebrowser.",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "org.chromium.Chromium",
];

/// Pid et instant de la dernière ouverture d'arbre demandée.
static TREE_ENABLED: std::sync::Mutex<Option<(i32, std::time::Instant)>> = std::sync::Mutex::new(None);

/// Chromium et Electron ne construisent leur arbre d'Accessibilité que si on
/// le leur demande ; il arrive ~2 s plus tard et reste ensuite pour la vie de
/// l'app. Appelé à l'appui sur le raccourci du mode commande, pour que la
/// sélection soit lisible au relâchement. Sans effet sur les apps natives.
pub fn enable_accessibility_tree(bundle_id: &str) {
    let Some(app) = frontmost_ax_app(0.2) else { return };
    let mut attrs = vec!["AXManualAccessibility"];
    if CHROMIUM.iter().any(|p| bundle_id.starts_with(p)) {
        attrs.push("AXEnhancedUserInterface");
    }
    unsafe {
        for attr in attrs {
            let name = CFString::new(attr);
            AXUIElementSetAttributeValue(
                app.as_CFTypeRef() as _,
                name.as_concrete_TypeRef(),
                CFBoolean::true_value().as_CFTypeRef(),
            );
        }
    }
    if let Some(pid) = frontmost_pid() {
        *TREE_ENABLED.lock().unwrap() = Some((pid, std::time::Instant::now()));
    }
}

/// L'arbre de l'app au premier plan a été demandé il y a moins de `within`.
pub fn tree_recently_enabled(within: Duration) -> bool {
    let pid = frontmost_pid();
    TREE_ENABLED.lock().unwrap().is_some_and(|(p, at)| Some(p) == pid && at.elapsed() < within)
}

/// Titre de la fenêtre au premier plan (onglet actif d'un navigateur).
pub fn front_window_title() -> Option<String> {
    unsafe {
        let app = frontmost_ax_app(0.15)?;
        let window = ax_copy(app.as_CFTypeRef() as _, "AXFocusedWindow")?;
        let title = ax_copy(window.as_CFTypeRef() as _, "AXTitle")?;
        title.downcast::<CFString>().map(|s| s.to_string())
    }
}

/// Texte sélectionné dans l'élément qui a le focus (`AXSelectedText`), lu
/// depuis l'app au premier plan. Une demi-seconde au plus si l'app ne
/// répond pas.
pub fn selected_text() -> Selection {
    unsafe {
        let focused = frontmost_ax_app(0.5).and_then(|app| ax_copy(app.as_CFTypeRef() as _, "AXFocusedUIElement"));
        let focused = focused.or_else(|| {
            let system = AXUIElementCreateSystemWide();
            if system.is_null() {
                return None;
            }
            let system = core_foundation::base::CFType::wrap_under_create_rule(system as _);
            AXUIElementSetMessagingTimeout(system.as_CFTypeRef() as _, 0.5);
            ax_copy(system.as_CFTypeRef() as _, "AXFocusedUIElement")
        });
        let Some(focused) = focused else {
            return Selection::Unknown;
        };
        let Some(value) = ax_copy(focused.as_CFTypeRef() as _, "AXSelectedText") else {
            return Selection::Unknown;
        };
        match value.downcast::<CFString>().map(|s| s.to_string()) {
            Some(s) if s.trim().is_empty() => {
                // Chromium / Electron renvoient parfois "" sans vraiment
                // exposer le texte : on ne croit au vide que si la plage de
                // sélection existe et est vide.
                let range = ax_copy(focused.as_CFTypeRef() as _, "AXSelectedTextRange").and_then(|v| {
                    let mut r = core_foundation::base::CFRange { location: 0, length: 0 };
                    AXValueGetValue(v.as_CFTypeRef(), AX_VALUE_CF_RANGE, &mut r as *mut _ as *mut _).then_some(r)
                });
                match range {
                    Some(r) if r.length == 0 => Selection::Empty,
                    _ => Selection::Unknown,
                }
            }
            Some(s) => Selection::Text(s),
            None => Selection::Unknown,
        }
    }
}

/// Repli pour les apps sans Accessibilité texte (Zed, Electron ou Chromium
/// dont l'arbre n'est pas encore prêt) : ⌘C, lecture, puis presse-papiers
/// remis comme avant.
/// Bloquant ~300 ms au plus : hors du fil principal.
pub fn copy_selection() -> Option<String> {
    let saved = snapshot();
    let before = change_count();
    press_cmd(KEY_C);
    let mut changed = false;
    for _ in 0..15 {
        std::thread::sleep(Duration::from_millis(20));
        if change_count() != before {
            changed = true;
            break;
        }
    }
    if !changed {
        return None;
    }
    let text = unsafe { NSPasteboard::generalPasteboard().stringForType(NSPasteboardTypeString) }.map(|s| s.to_string());
    restore(saved);
    text.filter(|t| !t.trim().is_empty())
}

/// Nom de l'app au premier plan (pour l'historique).
pub fn frontmost_app() -> Option<String> {
    unsafe {
        let ws = NSWorkspace::sharedWorkspace();
        let app = ws.frontmostApplication()?;
        app.localizedName().map(|n| n.to_string())
    }
}

// ── Sons ────────────────────────────────────────────────────────────────────

pub fn play(sound: &str) {
    let path = format!("/System/Library/Sounds/{sound}.aiff");
    std::thread::spawn(move || {
        let _ = std::process::Command::new("afplay").args(["-v", "0.35", &path]).status();
    });
}
