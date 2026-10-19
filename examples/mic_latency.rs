//! Mesure le temps d'ouverture du micro, étape par étape, sur plusieurs
//! ouvertures successives dans le même processus.
//! `cargo run --release --example mic_latency`
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

fn main() {
    for i in 0..6 {
        let t0 = Instant::now();
        let host = cpal::default_host();
        let t_host = t0.elapsed();
        let device = host.default_input_device().expect("micro");
        let t_dev = t0.elapsed();
        let supported = device.default_input_config().expect("config");
        let t_cfg = t0.elapsed();
        let config: cpal::StreamConfig = supported.clone().into();
        let (tx, rx) = mpsc::channel::<Instant>();
        let mut sent = false;
        let stream = device
            .build_input_stream(
                &config,
                move |_d: &[f32], _| {
                    if !sent {
                        sent = true;
                        let _ = tx.send(Instant::now());
                    }
                },
                |e| eprintln!("err {e}"),
                None,
            )
            .expect("build");
        let t_build = t0.elapsed();
        stream.play().expect("play");
        let t_play = t0.elapsed();
        let first = rx.recv_timeout(Duration::from_secs(3)).map(|t| t - t0);
        println!(
            "#{i} host {:>4} dev {:>4} cfg {:>4} build {:>4} play {:>4} 1er tampon {:>4} ms ({} Hz {:?})",
            t_host.as_millis(),
            t_dev.as_millis(),
            t_cfg.as_millis(),
            t_build.as_millis(),
            t_play.as_millis(),
            first.map(|d| d.as_millis() as i64).unwrap_or(-1),
            config.sample_rate.0,
            supported.sample_format()
        );
        std::thread::sleep(Duration::from_millis(300));
        drop(stream);
        std::thread::sleep(Duration::from_millis(if i == 3 { 3000 } else { 500 }));
    }
}
