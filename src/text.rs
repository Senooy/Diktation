//! Mise en forme du texte transcrit, entièrement locale et déterministe :
//! mots de remplissage, commandes vocales, corrections du dictionnaire,
//! raccourcis vocaux.

use crate::prefs::Prefs;

pub fn process(raw: &str, prefs: &Prefs) -> String {
    let mut s = raw.trim().to_string();
    if prefs.remove_fillers {
        s = remove_fillers(&s);
    }
    for r in &prefs.replacements {
        if !r.from.trim().is_empty() {
            s = replace_words(&s, r.from.trim(), &r.to);
        }
    }
    // Un raccourci vocal dit seul remplace toute la dictée ; dit au milieu
    // d'une phrase, il est remplacé sur place.
    for sn in &prefs.snippets {
        let trigger = sn.trigger.trim();
        if trigger.is_empty() {
            continue;
        }
        if normalize(&s) == normalize(trigger) {
            return sn.text.clone();
        }
        s = replace_words(&s, trigger, &sn.text);
    }
    if prefs.voice_commands {
        s = voice_commands(&s);
    }
    tidy(&s)
}

/// Comparaison souple : minuscules, sans ponctuation.
fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

const FILLERS: [&str; 9] = ["euh", "heu", "euuh", "hum", "hmm", "mmh", "um", "uh", "erm"];

fn remove_fillers(s: &str) -> String {
    let mut out = s.to_string();
    for f in FILLERS {
        out = replace_words(&out, f, "");
    }
    out
}

/// Remplace `from` (insensible à la casse et aux accents, mot entier) par
/// `to`. Quand `to` est vide, la virgule qui suit est retirée aussi.
pub fn replace_words(s: &str, from: &str, to: &str) -> String {
    let src: Vec<char> = s.chars().collect();
    let hay: Vec<char> = src.iter().map(|&c| fold(c)).collect();
    let needle: Vec<char> = from.chars().map(fold).collect();
    if needle.is_empty() || needle.len() > hay.len() {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < src.len() {
        let hit = i + needle.len() <= hay.len()
            && hay[i..i + needle.len()] == needle[..]
            && (i == 0 || !src[i - 1].is_alphanumeric())
            && src.get(i + needle.len()).is_none_or(|c| !c.is_alphanumeric());
        if hit {
            out.push_str(to);
            i += needle.len();
            if to.is_empty() && src.get(i) == Some(&',') {
                i += 1;
            }
        } else {
            out.push(src[i]);
            i += 1;
        }
    }
    out
}

/// Minuscule sans accent, un caractère pour un caractère.
fn fold(c: char) -> char {
    let l = c.to_lowercase().next().unwrap_or(c);
    match l {
        'à' | 'â' | 'ä' | 'á' | 'ã' => 'a',
        'é' | 'è' | 'ê' | 'ë' => 'e',
        'î' | 'ï' | 'í' => 'i',
        'ô' | 'ö' | 'ó' => 'o',
        'ù' | 'û' | 'ü' | 'ú' => 'u',
        'ç' => 'c',
        'ÿ' => 'y',
        '’' => '\'',
        _ => l,
    }
}

fn voice_commands(s: &str) -> String {
    let mut out = s.to_string();
    for (cmd, rep) in [
        ("nouveau paragraphe", "\n\n"),
        ("retour à la ligne", "\n"),
        ("à la ligne", "\n"),
        ("nouvelle ligne", "\n"),
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
    ] {
        out = replace_command(&out, cmd, rep);
    }
    out
}

/// Comme `replace_words`, mais absorbe la ponctuation que whisper met autour
/// de la commande (« Bonjour. À la ligne. Merci » → « Bonjour.\nMerci »).
fn replace_command(s: &str, cmd: &str, rep: &str) -> String {
    let marker = "\u{1}";
    let replaced = replace_words(s, cmd, marker);
    if !replaced.contains(marker) {
        return s.to_string();
    }
    let mut out = String::new();
    for (idx, part) in replaced.split(marker).enumerate() {
        let part = if idx == 0 {
            part.trim_end_matches([' ', ','])
        } else {
            part.trim_start_matches(['.', ',', ' ', '!', '?'])
        };
        if idx > 0 {
            out.push_str(rep);
        }
        let mut p = part.to_string();
        if idx > 0 {
            p = capitalize_first(&p);
        }
        out.push_str(&p);
    }
    out
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Espaces en trop, majuscule initiale, ponctuation orpheline.
fn tidy(s: &str) -> String {
    let lines: Vec<String> = s
        .split('\n')
        .map(|line| {
            let mut l = line.split_whitespace().collect::<Vec<_>>().join(" ");
            for p in [" ,", " ."] {
                while l.contains(p) {
                    l = l.replace(p, &p[1..]);
                }
            }
            let l = l.trim_start_matches([',', '.', ' ']).to_string();
            capitalize_first(&l)
        })
        .collect();
    lines.join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prefs::{Replacement, Snippet};

    #[test]
    fn fillers_and_commands() {
        let p = Prefs::default();
        assert_eq!(process("Euh, bonjour Marc. À la ligne. Merci, euh, pour tout.", &p), "Bonjour Marc.\nMerci, pour tout.");
        assert_eq!(process("Heureux de te voir", &p), "Heureux de te voir");
        assert_eq!(process("Merci. A la ligne. Bonne journée", &p), "Merci.\nBonne journée");
    }

    #[test]
    fn snippets_and_replacements() {
        let mut p = Prefs::default();
        p.snippets.push(Snippet { trigger: "mon adresse mail".into(), text: "younes@example.com".into() });
        p.replacements.push(Replacement { from: "dictation".into(), to: "Diktation".into() });
        assert_eq!(process("Mon adresse mail.", &p), "younes@example.com");
        assert_eq!(process("Écris à mon adresse mail sur dictation", &p), "Écris à younes@example.com sur Diktation");
    }
}
