//! Timestamped microphone/system mixing, fed by the native macOS capture bridge.
//! Audio callbacks use this lock only, never the database/UI core lock.
use crate::engine::SAMPLE_RATE;
use std::sync::Mutex;
const MAX: usize = SAMPLE_RATE as usize * 3600;
const SETTLE: usize = SAMPLE_RATE as usize / 2;

struct Timeline {
    id: i64,
    samples: Vec<f32>,
    ends: [usize; 2],
}
impl Timeline {
    fn new(id: i64) -> Self {
        Self {
            id,
            samples: Vec::new(),
            ends: [0, 0],
        }
    }
    fn push(&mut self, track: usize, offset: usize, samples: &[f32]) -> bool {
        if track > 1
            || offset >= MAX
            || samples.len() > SAMPLE_RATE as usize * 2
            || samples.iter().any(|x| !x.is_finite())
        {
            return false;
        }
        // Trim repeated/overlapping packets from the same source, not the other source.
        let skip = self.ends[track].saturating_sub(offset).min(samples.len());
        let start = offset + skip;
        let count = (samples.len() - skip).min(MAX.saturating_sub(start));
        if count == 0 {
            return true;
        }
        let end = start + count;
        self.samples.resize(self.samples.len().max(end), 0.);
        for (out, input) in self.samples[start..end]
            .iter_mut()
            .zip(&samples[skip..skip + count])
        {
            // Fixed headroom keeps simultaneous sources from clipping. Never append tracks sequentially.
            *out += input.clamp(-1., 1.) * 0.5;
        }
        self.ends[track] = end;
        true
    }
    fn chunk(&self, offset: usize, count: usize) -> Option<Vec<f32>> {
        let end = offset.checked_add(count)?;
        // A short tail lets the other device's callbacks catch up before preview/checkpoint.
        if end > self.samples.len().saturating_sub(SETTLE) {
            return None;
        }
        Some(self.samples.get(offset..end)?.to_vec())
    }
}
static INPUT: Mutex<Option<Timeline>> = Mutex::new(None);
pub fn begin(id: i64) {
    *INPUT.lock().unwrap() = Some(Timeline::new(id));
}
pub fn push(id: i64, track: usize, offset: usize, samples: &[f32]) -> bool {
    INPUT
        .lock()
        .unwrap()
        .as_mut()
        .filter(|t| t.id == id)
        .is_some_and(|t| t.push(track, offset, samples))
}
pub fn chunk(id: i64, offset: usize, count: usize) -> Option<Vec<f32>> {
    INPUT
        .lock()
        .unwrap()
        .as_ref()
        .filter(|t| t.id == id)?
        .chunk(offset, count)
}
pub fn finish(id: i64) -> Vec<f32> {
    let mut input = INPUT.lock().unwrap();
    if input.as_ref().is_some_and(|t| t.id == id) {
        input.take().unwrap().samples
    } else {
        Vec::new()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn concurrent_sources_are_mixed_on_one_timeline() {
        let mut t = Timeline::new(1);
        assert!(t.push(0, 0, &[1., 1., 1., 1.]));
        assert!(t.push(1, 2, &[0.5, 0.5]));
        assert_eq!(t.samples, vec![0.5, 0.5, 0.75, 0.75]);
        assert!(t.push(1, 2, &[0.5, 0.5]));
        assert_eq!(t.samples, vec![0.5, 0.5, 0.75, 0.75]);
    }
    #[test]
    fn gaps_and_late_other_track_keep_timestamps() {
        let mut t = Timeline::new(2);
        t.push(1, 4, &[1., 1.]);
        t.push(0, 0, &[0.5, 0.5]);
        assert_eq!(t.samples, vec![0.25, 0.25, 0., 0., 0.5, 0.5]);
        assert!(!t.push(0, MAX, &[1.]));
        assert!(!t.push(2, 0, &[1.]));
        assert!(!t.push(0, 2, &[f32::NAN]));
    }
    #[test]
    fn preview_waits_for_tail_but_a_silent_source_cannot_block_it() {
        let mut t = Timeline::new(3);
        t.push(0, 0, &vec![0.; 16000]);
        assert!(t.chunk(0, 16000).is_none());
        t.push(0, 16000, &vec![0.; 8000]);
        assert_eq!(t.chunk(0, 16000).unwrap().len(), 16000);
    }
}
