//! Diktation : dictée vocale locale pour macOS. Cœur en Rust (raccourci
//! global, micro, whisper.cpp, collage, Apple Intelligence), interface en
//! Swift (`app/`) par l'API C de `ffi.rs`.

pub mod assist;
pub mod audio;
pub mod core;
pub mod engine;
pub mod ffi;
pub mod hotkey;
pub mod i18n;
pub mod llm;
pub mod macos;
pub mod meetings;
pub mod meeting_audio;
pub mod prefs;
pub mod store;
pub mod speakers;
pub mod text;
