//! Langue de l'interface : français si le Mac est en français, anglais
//! sinon. L'app Swift la fixe dans `DIKTATION_LANG` avant de lancer le cœur
//! (l'outil `diktation-llm` en hérite) ; sans elle (outils en ligne de
//! commande), on lit la langue préférée du Mac.

use std::sync::OnceLock;

static FRENCH: OnceLock<bool> = OnceLock::new();

pub fn is_french() -> bool {
    *FRENCH.get_or_init(|| match std::env::var("DIKTATION_LANG") {
        Ok(v) => v.starts_with("fr"),
        Err(_) => mac_prefers_french(),
    })
}

fn mac_prefers_french() -> bool {
    std::process::Command::new("defaults")
        .args(["read", "-g", "AppleLanguages"])
        .output()
        .ok()
        .and_then(|o| {
            let text = String::from_utf8_lossy(&o.stdout).to_string();
            text.split(['"', ',', '(', ')', '\n', ' ']).find(|s| !s.trim().is_empty()).map(|s| s.trim().starts_with("fr"))
        })
        .unwrap_or(false)
}

/// Texte selon la langue de l'interface.
pub fn tr(fr: &'static str, en: &'static str) -> &'static str {
    if is_french() { fr } else { en }
}
