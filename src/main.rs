//! Outils de test en ligne de commande, sans interface (l'app elle-même est
//! en Swift, dans `app/`, et lie le cœur comme bibliothèque statique).
//!
//! - `diktation --transcribe fichier.wav [modèle]` (identifiant du catalogue)
//! - `diktation --rewrite <bundle id> "texte" ["titre de fenêtre"]`
//! - `diktation --command "consigne" ["sélection"]`
//! - `diktation --selection` (lit la sélection de l'app au premier plan)

use std::time::{Duration, Instant};

use diktation::core::{read_selection, rewrite, run_command};
use diktation::engine::{self, Engine};
use diktation::prefs::Prefs;
use diktation::{assist, audio, llm, macos, text};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--transcribe") if args.len() >= 3 => cli_transcribe(&args[2], args.get(3).map(String::as_str)),
        Some("--rewrite") if args.len() >= 4 => cli_rewrite(&args[2], &args[3], args.get(4).map(String::as_str)),
        Some("--command") if args.len() >= 3 => cli_command(&args[2], args.get(3).map(String::as_str)),
        Some("--selection") => cli_selection(),
        _ => eprintln!(
            "usage : diktation --transcribe f.wav | --rewrite <bundle id> \"texte\" [titre] | --command \"consigne\" [sélection] | --selection"
        ),
    }
}

fn cli_transcribe(path: &str, model: Option<&str>) {
    let prefs = Prefs::load();
    let model = engine::resolve_model(model.unwrap_or(&prefs.model)).expect("aucun modèle");
    eprintln!("modèle : {}", model.display());
    let t = Instant::now();
    let eng = Engine::load(&model).expect("chargement");
    eprintln!("modèle chargé en {:?}", t.elapsed());
    let samples = audio::load_wav(std::path::Path::new(path)).expect("wav");
    let out = eng
        .transcribe(&samples, &prefs.language, &engine::build_prompt(&prefs.dictionary, &prefs.language))
        .expect("transcription");
    println!("[{} ms] brut : {}", out.millis, out.text);
    println!("final : {}", text::process(&out.text, &prefs));
}

fn cli_rewrite(bundle_id: &str, text: &str, title: Option<&str>) {
    let prefs = Prefs::load();
    let llm = llm::Llm::new();
    let category = assist::category_in(bundle_id, title);
    let tone = prefs.tones.get(category);
    let Some(instructions) = assist::rewrite_instructions(category, tone, &prefs.dictionary) else {
        return println!("{} : ton « {} », pas de reformulation", category.label(), tone.label());
    };
    let t = Instant::now();
    let out = rewrite(&llm, &instructions, text::process(text, &prefs), &prefs);
    println!("[{} · {} · {} ms] {out}", category.label(), tone.label(), t.elapsed().as_millis());
}

fn cli_command(instruction: &str, selection: Option<&str>) {
    let llm = llm::Llm::new();
    let t = Instant::now();
    match run_command(&llm, instruction, selection) {
        Ok(out) => println!("[{} ms] {out}", t.elapsed().as_millis()),
        Err(e) => println!("[{} ms] erreur : {e}", t.elapsed().as_millis()),
    }
}

/// Comme un appui sur le raccourci du mode commande : arbre d'Accessibilité
/// demandé, ~1,5 s de consigne, puis lecture.
fn cli_selection() {
    std::thread::sleep(Duration::from_secs(1));
    macos::enable_accessibility_tree(&macos::frontmost_bundle_id().unwrap_or_default());
    std::thread::sleep(Duration::from_millis(1500));
    let t = Instant::now();
    let selection = read_selection();
    let how = match macos::selected_text() {
        macos::Selection::Text(_) => "Accessibilité",
        macos::Selection::Empty => "Accessibilité (vide)",
        macos::Selection::Unknown => "indisponible",
    };
    let bundle_id = macos::frontmost_bundle_id().unwrap_or_default();
    let title = macos::front_window_title();
    println!("{selection:?} (lue en {} ms, Accessibilité ensuite : {how})", t.elapsed().as_millis());
    println!("fenêtre {title:?} → {}", assist::category_in(&bundle_id, title.as_deref()).label());
}
