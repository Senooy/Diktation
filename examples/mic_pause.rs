//! Flux construit une fois, puis cycles pause/reprise : temps de reprise et
//! état « micro en marche » vu par CoreAudio (ce qui allume le voyant).
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

#[repr(C)]
struct Addr { sel: u32, scope: u32, elem: u32 }
#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    fn AudioObjectGetPropertyData(id: u32, a: *const Addr, qs: u32, q: *const u8, size: *mut u32, out: *mut u8) -> i32;
}
const fn fcc(s: &[u8; 4]) -> u32 { u32::from_be_bytes(*s) }
fn get_u32(id: u32, sel: &[u8; 4]) -> u32 {
    let a = Addr { sel: fcc(sel), scope: fcc(b"glob"), elem: 0 };
    let mut v = 0u32; let mut sz = 4u32;
    unsafe { AudioObjectGetPropertyData(id, &a, 0, std::ptr::null(), &mut sz, &mut v as *mut u32 as *mut u8) };
    v
}
fn running() -> (u32, u32) {
    let dev = get_u32(1, b"dIn ");
    (get_u32(dev, b"goin"), get_u32(dev, b"gone"))
}

fn main() {
    let t0 = Instant::now();
    let host = cpal::default_host();
    let device = host.default_input_device().unwrap();
    let config: cpal::StreamConfig = device.default_input_config().unwrap().into();
    let frames = Arc::new(AtomicU64::new(0));
    let f = frames.clone();
    let stream = device.build_input_stream(&config, move |d: &[f32], _| { f.fetch_add(d.len() as u64, Ordering::SeqCst); }, |e| eprintln!("{e}"), None).unwrap();
    println!("construit+démarré en {} ms, en marche {:?}", t0.elapsed().as_millis(), running());
    std::thread::sleep(Duration::from_millis(300));
    stream.pause().unwrap();
    std::thread::sleep(Duration::from_millis(500));
    println!("en pause : en marche (ici, partout) {:?}", running());
    for i in 0..5 {
        let before = frames.load(Ordering::SeqCst);
        let t = Instant::now();
        stream.play().unwrap();
        let t_play = t.elapsed();
        while frames.load(Ordering::SeqCst) == before { std::thread::yield_now(); }
        println!("#{i} play {} ms, 1er tampon {} ms, en marche {:?}", t_play.as_millis(), t.elapsed().as_millis(), running());
        std::thread::sleep(Duration::from_millis(300));
        let t = Instant::now();
        stream.pause().unwrap();
        let tp = t.elapsed();
        std::thread::sleep(Duration::from_millis(200));
        println!("   pause {} ms, en marche {:?}", tp.as_millis(), running());
        std::thread::sleep(Duration::from_millis(800));
    }
}
