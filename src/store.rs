//! Historique local des dictées (SQLite) et audio associé (WAV).

use std::path::PathBuf;

use anyhow::Result;
use rusqlite::{Connection, params};

use crate::prefs::data_dir;

#[derive(Clone, Debug)]
pub struct Entry {
    pub id: i64,
    pub at: i64,
    pub text: String,
    pub app: String,
    pub seconds: f32,
    pub millis: i64,
    pub audio: Option<PathBuf>,
    pub turns: Vec<crate::speakers::Turn>,
}

pub struct Store {
    db: Connection,
}

pub fn audio_dir() -> PathBuf {
    data_dir().join("audio")
}

impl Store {
    pub fn open() -> Result<Self> {
        std::fs::create_dir_all(data_dir())?;
        let db = Connection::open(data_dir().join("history.sqlite"))?;
        Self::from_connection(db)
    }

    fn from_connection(db: Connection) -> Result<Self> {
        db.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE IF NOT EXISTS dictation (
                id INTEGER PRIMARY KEY,
                at INTEGER NOT NULL,
                text TEXT NOT NULL,
                raw TEXT NOT NULL,
                app TEXT NOT NULL DEFAULT '',
                seconds REAL NOT NULL DEFAULT 0,
                millis INTEGER NOT NULL DEFAULT 0,
                audio TEXT
             );",
        )?;
        db.execute_batch("CREATE TABLE IF NOT EXISTS speaker_analysis (
            dictation_id INTEGER PRIMARY KEY,
            turns TEXT NOT NULL
        );")?;
        Ok(Self { db })
    }

    pub fn add(&self, text: &str, raw: &str, app: &str, seconds: f32, millis: i64, audio: Option<&PathBuf>) -> Result<i64> {
        let at = chrono::Local::now().timestamp();
        self.db.execute(
            "INSERT INTO dictation (at, text, raw, app, seconds, millis, audio) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![at, text, raw, app, seconds, millis, audio.map(|p| p.to_string_lossy().into_owned())],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    pub fn update_text(&self, id: i64, text: &str, raw: &str, millis: i64, audio: &std::path::Path) -> Result<()> {
        self.db.execute("UPDATE dictation SET text = ?2, raw = ?3, millis = ?4 WHERE id = ?1 AND audio = ?5", params![id, text, raw, millis, audio.to_string_lossy()])?;
        Ok(())
    }

    pub fn update_turns(&self, id: i64, turns: &[crate::speakers::Turn], audio: &std::path::Path) -> Result<()> {
        // A deleted recording must never be resurrected by a late worker result.
        self.db.execute("INSERT OR REPLACE INTO speaker_analysis (dictation_id, turns)
            SELECT id, ?2 FROM dictation WHERE id = ?1 AND audio = ?3", params![id, serde_json::to_string(turns)?, audio.to_string_lossy()])?;
        Ok(())
    }

    pub fn recent(&self, limit: usize) -> Vec<Entry> {
        let Ok(mut st) = self.db.prepare(
            "SELECT id, at, text, raw, app, seconds, millis, audio,
                (SELECT turns FROM speaker_analysis WHERE dictation_id = dictation.id)
                FROM dictation ORDER BY id DESC LIMIT ?1",
        ) else {
            return Vec::new();
        };
        st.query_map([limit as i64], |r| {
            Ok(Entry {
                id: r.get(0)?,
                at: r.get(1)?,
                text: r.get(2)?,
                app: r.get(4)?,
                seconds: r.get::<_, f64>(5)? as f32,
                millis: r.get(6)?,
                audio: r.get::<_, Option<String>>(7)?.map(PathBuf::from),
                turns: r.get::<_, Option<String>>(8)?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default(),
            })
        })
        .map(|rows| rows.filter_map(Result::ok).collect())
        .unwrap_or_default()
    }

    pub fn last_text(&self) -> Option<String> {
        self.db
            .query_row("SELECT text FROM dictation WHERE text != '' ORDER BY id DESC LIMIT 1", [], |r| r.get(0))
            .ok()
    }

    pub fn delete(&self, id: i64) {
        if let Ok(Some(path)) =
            self.db.query_row("SELECT audio FROM dictation WHERE id = ?1", [id], |r| r.get::<_, Option<String>>(0))
        {
            let _ = std::fs::remove_file(path);
        }
        let _ = self.db.execute("DELETE FROM speaker_analysis WHERE dictation_id = ?1", [id]);
        let _ = self.db.execute("DELETE FROM dictation WHERE id = ?1", [id]);
    }

    /// Supprime ce qui a plus de `hours` heures (texte et audio).
    pub fn prune_older_than(&self, hours: i64) {
        let limit = chrono::Local::now().timestamp() - hours * 3600;
        let ids: Vec<i64> = self
            .db
            .prepare("SELECT id FROM dictation WHERE at < ?1")
            .and_then(|mut st| st.query_map([limit], |r| r.get(0)).map(|rows| rows.filter_map(Result::ok).collect()))
            .unwrap_or_default();
        for id in ids {
            self.delete(id);
        }
    }

    pub fn clear(&self) {
        let _ = self.db.execute("DELETE FROM speaker_analysis", []);
        let _ = self.db.execute("DELETE FROM dictation", []);
        let _ = std::fs::remove_dir_all(audio_dir());
    }

    /// Statistiques : (nombre de dictées, mots, secondes parlées).
    pub fn stats(&self) -> (i64, i64, f64) {
        let (n, secs): (i64, f64) = self
            .db
            .query_row("SELECT COUNT(*), COALESCE(SUM(seconds), 0) FROM dictation", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap_or((0, 0.0));
        let words: i64 = self
            .db
            .prepare("SELECT text FROM dictation")
            .and_then(|mut st| {
                st.query_map([], |r| r.get::<_, String>(0))
                    .map(|rows| rows.filter_map(Result::ok).map(|t| t.split_whitespace().count() as i64).sum())
            })
            .unwrap_or(0);
        (n, words, secs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn speaker_results_survive_reads_and_cannot_update_reused_ids() {
        let store = Store::from_connection(Connection::open_in_memory().unwrap()).unwrap();
        let path = PathBuf::from("/nonexistent/recording-one.wav");
        let id = store.add("original", "raw", "", 4., 100, Some(&path)).unwrap();
        let turn = crate::speakers::Turn { start: 0., end: 4., speaker: 1, text: "hello".into(), overlap: false };
        store.update_turns(id, std::slice::from_ref(&turn), &path).unwrap();
        let entries = store.recent(10);
        assert_eq!(entries[0].text, "original");
        assert_eq!(entries[0].turns, vec![turn.clone()]);
        store.delete(id);
        let next_path = PathBuf::from("/nonexistent/recording-two.wav");
        let next = store.add("new recording", "raw", "", 4., 100, Some(&next_path)).unwrap();
        assert_eq!(next, id); // SQLite may reuse the last deleted rowid.
        store.update_turns(id, &[turn], &path).unwrap();
        store.update_text(id, "stale", "stale", 200, &path).unwrap();
        let entries = store.recent(10);
        assert_eq!(entries[0].text, "new recording");
        assert!(entries[0].turns.is_empty());
    }

    #[test]
    fn existing_history_migrates_without_losing_text() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE dictation (id INTEGER PRIMARY KEY, at INTEGER NOT NULL,
            text TEXT NOT NULL, raw TEXT NOT NULL, app TEXT, seconds REAL, millis INTEGER, audio TEXT);
            INSERT INTO dictation VALUES (1, 0, 'kept', 'raw', '', 2, 100, NULL);").unwrap();
        let store = Store::from_connection(db).unwrap();
        assert_eq!(store.recent(10)[0].text, "kept");
        assert!(store.recent(10)[0].turns.is_empty());
    }
}
