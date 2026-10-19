//! Après la reprise d'un flux en pause : délai jusqu'au premier tampon, puis
//! jusqu'au premier échantillon non nul (le micro intégré rend d'abord des
//! zéros). `cargo run --release --example mic_warmup [taille_tampon]`
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

#[derive(Default)]
struct Seen {
    first: Option<Instant>,
    nonzero: Option<Instant>,
    /// Crête de chaque tampon (×10⁴) avec son heure d'arrivée.
    peaks: Vec<(Instant, u32)>,
}

fn main() {
    let device = cpal::default_host().default_input_device().unwrap();
    let mut config: cpal::StreamConfig = device.default_input_config().unwrap().into();
    if let Some(n) = std::env::args().nth(1) {
        config.buffer_size = cpal::BufferSize::Fixed(n.parse().unwrap());
    }
    let seen = Arc::new(Mutex::new(Seen::default()));
    let s = seen.clone();
    let stream = device
        .build_input_stream(
            &config,
            move |d: &[f32], _| {
                let mut s = s.lock().unwrap();
                let now = Instant::now();
                s.first.get_or_insert(now);
                let peak = d.iter().fold(0f32, |m, x| m.max(x.abs()));
                // Seuil : bruit de fond normal d'une pièce calme (~1e-3).
                if s.nonzero.is_none() && peak > 1e-3 {
                    s.nonzero = Some(now);
                }
                s.peaks.push((now, (peak * 1e4) as u32));
            },
            |e| eprintln!("{e}"),
            None,
        )
        .unwrap();
    std::thread::sleep(Duration::from_millis(500));
    for pause_ms in [300u64, 1000, 3000, 300, 1000] {
        stream.pause().unwrap();
        std::thread::sleep(Duration::from_millis(pause_ms));
        *seen.lock().unwrap() = Seen::default();
        let t = Instant::now();
        stream.play().unwrap();
        std::thread::sleep(Duration::from_millis(600));
        let s = seen.lock().unwrap();
        let ms = |i: Option<Instant>| i.map_or(-1, |i| (i - t).as_millis() as i64);
        println!("pause {pause_ms:>4} ms → 1er tampon {:>3} ms, bruit de fond atteint {:>3} ms", ms(s.first), ms(s.nonzero));
        let p: Vec<String> = s.peaks.iter().take(30).map(|(i, p)| format!("{}:{p}", (*i - t).as_millis())).collect();
        println!("    {}", p.join(" "));
    }
}
