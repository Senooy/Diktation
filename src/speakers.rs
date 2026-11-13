//! Local speaker diarization, separate from the latency-sensitive dictation path.
//! Labels describe voices within one recording, not identities across recordings.
use std::path::Path;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{engine::{self, Engine, SAMPLE_RATE}, prefs::Prefs};

const SEGMENTATION: &str = "sherpa-onnx-pyannote-segmentation-3-0";
const EMBEDDING: &str = "nemo_en_titanet_small.onnx";
const EMBEDDING_BYTES: u64 = 40_257_283;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Turn {
    pub start: f32,
    pub end: f32,
    pub speaker: usize,
    pub text: String,
    pub overlap: bool,
}

pub fn installed() -> bool {
    let dir = engine::install_dir();
    dir.join(SEGMENTATION).join(engine::COMPLETE_MARKER).is_file()
        && dir.join(SEGMENTATION).join("model.onnx").is_file()
        && std::fs::metadata(dir.join(EMBEDDING)).is_ok_and(|m| m.len() == EMBEDDING_BYTES)
}

/// Uses the app's existing verified, resumable model downloader.
pub fn catalog() -> Vec<Value> {
    let dir = engine::install_dir();
    [
        (SEGMENTATION, "Segmentation · Pyannote 3.0", 6_958_444, true,
         "speaker-segmentation-models", format!("{SEGMENTATION}.tar.bz2")),
        (EMBEDDING, "Voix · NVIDIA TitaNet small", EMBEDDING_BYTES, false,
         "speaker-recongition-models", EMBEDDING.to_string()),
    ].into_iter().map(|(file, label, bytes, archive, release, name)| {
        let have = if archive {
            dir.join(file).join(engine::COMPLETE_MARKER).is_file() && dir.join(file).join("model.onnx").is_file()
        } else { std::fs::metadata(dir.join(file)).is_ok_and(|m| m.len() == bytes) };
        json!({"file":file, "label":label, "bytes":bytes, "engine":"diarization",
            "archive":archive, "archive_dir":file,
            "download":{"name":name,"url":format!("https://github.com/k2-fsa/sherpa-onnx/releases/download/{release}/{name}")},
            "supports_language":true, "recommended":false, "installed":have})
    }).collect()
}

pub struct Diarizer(sherpa_onnx::OfflineSpeakerDiarization);

impl Diarizer {
    pub fn load(dir: &Path) -> Result<Self> {
        let segmentation = dir.join(SEGMENTATION).join("model.onnx");
        let embedding = dir.join(EMBEDDING);
        ensure!(segmentation.is_file() && embedding.is_file(), "speaker models missing");
        let mut config = sherpa_onnx::OfflineSpeakerDiarizationConfig::default();
        config.segmentation.pyannote.model = Some(segmentation.to_string_lossy().into_owned());
        config.segmentation.num_threads = 2;
        config.embedding.model = Some(embedding.to_string_lossy().into_owned());
        config.embedding.num_threads = 2;
        let diarizer = sherpa_onnx::OfflineSpeakerDiarization::create(&config).context("loading speaker models")?;
        ensure!(diarizer.sample_rate() == SAMPLE_RATE as i32, "unsupported diarization sample rate");
        Ok(Self(diarizer))
    }

    pub fn analyze(&self, samples: &[f32], engine: &Engine, prefs: &Prefs, count: usize) -> Result<Vec<Turn>> {
        ensure!((SAMPLE_RATE as usize..=SAMPLE_RATE as usize * 60 * 60).contains(&samples.len()),
            "speaker analysis requires between 1 second and 1 hour of audio");
        ensure!(samples.iter().all(|x| x.is_finite()), "invalid audio samples");
        ensure!(count <= 20, "speaker count must be between 0 (auto) and 20");
        let mut config = sherpa_onnx::OfflineSpeakerDiarizationConfig::default();
        config.clustering.num_clusters = if count == 0 { -1 } else { count as i32 };
        self.0.set_config(&config);
        let result = self.0.process(samples).context("speaker analysis failed")?;
        let mut turns = normalize(result.sort_by_start_time(), samples.len() as f32 / SAMPLE_RATE as f32);
        validate_voice_count(&turns, count)?;
        let prompt = engine::build_prompt(&prefs.dictionary, &prefs.language);
        for turn in &mut turns {
            // No padding across turns: another speaker must not leak into this transcript.
            let start = (turn.start * SAMPLE_RATE as f32) as usize;
            let end = ((turn.end * SAMPLE_RATE as f32).ceil() as usize).min(samples.len());
            let mut parts = Vec::new();
            for range in engine::chunk_ranges(&samples[start..end], SAMPLE_RATE as usize * 25) {
                let chunk = &samples[start + range.start..start + range.end];
                if chunk.len() < SAMPLE_RATE as usize / 4 { continue; }
                let output = engine.transcribe_with_options(chunk, &prefs.language, &prompt, prefs.fast_transcription)?;
                if !output.text.is_empty() { parts.push(output.text); }
            }
            // Preserve what was said: no rewriting, snippets or voice commands in conversations.
            turn.text = parts.join(" ");
        }
        Ok(turns)
    }
}

fn validate_voice_count(turns: &[Turn], requested: usize) -> Result<()> {
    let voices = turns.iter().map(|t| t.speaker).collect::<std::collections::HashSet<_>>().len();
    let limit = if requested == 0 { 20 } else { requested };
    ensure!(voices <= limit, "{}", crate::i18n::tr(
        "La détection automatique a séparé trop de voix. Choisissez le nombre réel d’intervenants puis relancez la transcription. L’audio et les notes sont conservés.",
        "Too many voices were detected. Choose the actual speaker count and transcribe again. Audio and notes are preserved."
    ));
    Ok(())
}

fn normalize(segments: Vec<sherpa_onnx::OfflineSpeakerDiarizationSegment>, duration: f32) -> Vec<Turn> {
    let mut segments = segments.into_iter().filter(|s| s.start.is_finite() && s.end.is_finite() && s.speaker >= 0)
        .collect::<Vec<_>>();
    segments.sort_by(|a, b| a.start.total_cmp(&b.start).then(a.end.total_cmp(&b.end)));
    let mut voices = Vec::new();
    let mut turns: Vec<Turn> = Vec::new();
    for s in segments {
        let start = s.start.clamp(0.0, duration);
        let end = s.end.clamp(0.0, duration);
        if end - start < 0.1 { continue; }
        let speaker = match voices.iter().position(|id| *id == s.speaker) {
            Some(index) => index + 1,
            None => { voices.push(s.speaker); voices.len() }
        };
        // Merge adjacent fragments of the same voice, but preserve intervening turns.
        if let Some(last) = turns.last_mut()
            && last.speaker == speaker && start - last.end <= 0.35 {
            last.end = last.end.max(end);
        } else {
            turns.push(Turn { start, end, speaker, text: String::new(), overlap: false });
        }
    }
    for i in 0..turns.len() {
        for j in i + 1..turns.len() {
            if turns[j].start >= turns[i].end { break; }
            if turns[i].speaker != turns[j].speaker {
                turns[i].overlap = true;
                turns[j].overlap = true;
            }
        }
    }
    turns
}

#[cfg(test)]
mod tests {
    use super::*;
    fn segment(start: f32, end: f32, speaker: i32) -> sherpa_onnx::OfflineSpeakerDiarizationSegment {
        sherpa_onnx::OfflineSpeakerDiarizationSegment { start, end, speaker, confidence: 0.0 }
    }
    #[test]
    fn excessive_voice_counts_require_manual_correction() {
        let turns = (1..=198).map(|speaker| Turn { start: 0., end: 1., speaker, text: String::new(), overlap: false }).collect::<Vec<_>>();
        assert!(validate_voice_count(&turns, 0).is_err());
        assert!(validate_voice_count(&turns[..3], 3).is_ok());
        assert!(validate_voice_count(&turns[..4], 3).is_err());
    }
    #[test]
    fn labels_are_stable_and_overlaps_are_explicit() {
        let turns = normalize(vec![segment(3., 4., 8), segment(0., 1., 8), segment(1.1, 2., 8),
            segment(1.8, 2.8, 2), segment(f32::NAN, 4., 4), segment(8., 10., 2)], 9.);
        assert_eq!(turns.len(), 4);
        assert_eq!(turns.iter().map(|t| t.speaker).collect::<Vec<_>>(), vec![1, 2, 1, 2]);
        assert_eq!(turns[0].end, 2.);
        assert!(turns[0].overlap && turns[1].overlap);
        assert!(!turns[2].overlap);
        assert_eq!(turns[3].end, 9.);
    }
}
