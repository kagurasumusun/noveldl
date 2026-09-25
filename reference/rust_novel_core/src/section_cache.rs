use anyhow::Result;
use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::file_lock::with_exclusive_lock_timeout;

pub const CACHE_VERSION: u32 = 2;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheEntry {
    pub source_hash: String,
    pub converted_section: Value,
    #[serde(default)]
    pub use_dakuten_font: bool,
    #[serde(default)]
    pub updated_at: i64,
}
impl CacheEntry {
    pub fn valid_for(&self, source_hash: &str) -> bool {
        self.source_hash == source_hash
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CacheMeta {
    version: u32,
    settings_hash: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct ChunkMeta {
    version: u32,
    chunk_size: usize,
}

pub struct SectionCache {
    root: PathBuf,
    chunk_size: usize,
    memory_cache: RefCell<HashMap<String, CacheEntry>>,
    dirty_indexes: RefCell<HashSet<String>>,
    index_to_position: RefCell<HashMap<String, usize>>,
    hit_count: RefCell<usize>,
    miss_count: RefCell<usize>,
}

impl SectionCache {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            chunk_size: 200,
            memory_cache: RefCell::new(HashMap::new()),
            dirty_indexes: RefCell::new(HashSet::new()),
            index_to_position: RefCell::new(HashMap::new()),
            hit_count: RefCell::new(0),
            miss_count: RefCell::new(0),
        }
    }
    pub fn settings_fingerprint(settings: &HashMap<String, Value>) -> String {
        let mut pairs: Vec<(&str, &Value)> =
            settings.iter().map(|(k, v)| (k.as_str(), v)).collect();
        pairs.sort_by(|a, b| a.0.cmp(b.0));
        let canonical: serde_json::Map<String, Value> = pairs
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect();
        let digest = Sha256::digest(serde_json::to_vec(&canonical).unwrap_or_default());
        format!("sha256:{digest:x}")
    }
    pub fn compute_source_hash(section: &Value) -> String {
        let digest = Sha256::digest(serde_json::to_vec(section).unwrap_or_default());
        format!("sha256:{digest:x}")
    }

    pub fn load_toc_index_mapping(&self, toc_path: &std::path::Path) -> Result<()> {
        if !toc_path.exists() {
            return Ok(());
        }
        let raw = fs::read_to_string(toc_path)?;
        let v: serde_yaml::Value = serde_yaml::from_str(&raw)?;
        let mut map = HashMap::new();
        if let Some(subs) = v.get("subtitles").and_then(|x| x.as_sequence()) {
            for (i, s) in subs.iter().enumerate() {
                if let Some(idx) = s.get("index").and_then(|x| x.as_str()) {
                    map.insert(idx.to_string(), i + 1);
                }
            }
        }
        self.index_to_position.replace(map);
        Ok(())
    }
    fn normalize_index(&self, index: &str) -> String {
        self.index_to_position
            .borrow()
            .get(index)
            .map(|v| v.to_string())
            .unwrap_or_else(|| index.to_string())
    }

    pub fn get(&self, index: &str, original_section: &Value) -> Option<(Value, bool)> {
        let normalized = self.normalize_index(index);
        let source_hash = Self::compute_source_hash(original_section);
        let binding = self.memory_cache.borrow();
        if let Some(hit) = binding
            .get(&normalized)
            .filter(|e| e.valid_for(&source_hash))
        {
            *self.hit_count.borrow_mut() += 1;
            return Some((hit.converted_section.clone(), hit.use_dakuten_font));
        }
        *self.miss_count.borrow_mut() += 1;
        None
    }
    pub fn store(
        &self,
        index: &str,
        original_section: &Value,
        converted_section: Value,
        use_dakuten_font: bool,
    ) {
        let normalized = self.normalize_index(index);
        let source_hash = Self::compute_source_hash(original_section);
        let updated_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.memory_cache.borrow_mut().insert(
            normalized.clone(),
            CacheEntry {
                source_hash,
                converted_section,
                use_dakuten_font,
                updated_at,
            },
        );
        self.dirty_indexes.borrow_mut().insert(normalized);
    }

    pub fn merge_and_flush(
        &self,
        pending_stores: &[(String, Value, Value, bool)],
        settings_hash: &str,
    ) -> Result<()> {
        let lock_path = self.root.join(".merge.lock");
        with_exclusive_lock_timeout(&lock_path, Duration::from_secs(30), || {
            let _ = self.load_all();
            for (idx, original, converted, dakuten) in pending_stores {
                self.store(idx, original, converted.clone(), *dakuten);
            }
            self.flush(settings_hash)
        })
    }

    pub fn merge_and_flush_strict(
        &self,
        pending_stores: &[(String, Value, Value, bool)],
        settings_hash: &str,
    ) -> Result<()> {
        // strict variant for Ruby-parity sequencing: lock -> reload -> merge -> flush
        self.merge_and_flush(pending_stores, settings_hash)
    }

    pub fn statistics(&self) -> HashMap<&'static str, f64> {
        let hit = *self.hit_count.borrow() as f64;
        let miss = *self.miss_count.borrow() as f64;
        let mut m = HashMap::new();
        m.insert("hit_count", hit);
        m.insert("miss_count", miss);
        m.insert(
            "hit_rate",
            if (hit + miss) > 0.0 {
                (hit / (hit + miss) * 1000.0).round() / 10.0
            } else {
                0.0
            },
        );
        m.insert("dirty_indexes", self.dirty_indexes.borrow().len() as f64);
        m.insert("memory_entries", self.memory_cache.borrow().len() as f64);
        m
    }

    pub fn flush(&self, settings_hash: &str) -> Result<()> {
        if self.dirty_indexes.borrow().is_empty() {
            return Ok(());
        }
        self.save_all(&self.memory_cache.borrow(), settings_hash)?;
        self.dirty_indexes.borrow_mut().clear();
        Ok(())
    }
    fn meta_file(&self) -> PathBuf {
        self.root.join("meta.json")
    }
    fn chunk_file(&self, n: usize) -> PathBuf {
        self.root.join(format!("chunk_{:06}.json.gz", n))
    }
    pub fn validate_settings_hash(&self, expected_settings_hash: &str) -> Result<bool> {
        Ok(self
            .load_meta()?
            .map(|m| m.version == CACHE_VERSION && m.settings_hash == expected_settings_hash)
            .unwrap_or(false))
    }
    pub fn load_all(&self) -> Result<HashMap<String, CacheEntry>> {
        if !self.root.exists() {
            return Ok(HashMap::new());
        }
        let mut merged = HashMap::new();
        for e in fs::read_dir(&self.root)? {
            let p = e?.path();
            if p.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .starts_with("chunk_")
            {
                let mut d = GzDecoder::new(fs::File::open(&p)?);
                let mut raw = String::new();
                d.read_to_string(&mut raw)?;
                merged.extend(serde_json::from_str::<HashMap<String, CacheEntry>>(&raw)?);
            }
        }
        self.memory_cache.replace(merged.clone());
        Ok(merged)
    }
    pub fn save_all(&self, map: &HashMap<String, CacheEntry>, settings_hash: &str) -> Result<()> {
        fs::create_dir_all(&self.root)?;
        self.clear_chunks()?;
        let mut kv: Vec<_> = map.iter().collect();
        kv.sort_by(|a, b| a.0.cmp(b.0));
        for (chunk_no, chunk) in kv.chunks(self.chunk_size).enumerate() {
            let mut sub = HashMap::new();
            for (k, v) in chunk {
                sub.insert((*k).clone(), (*v).clone());
            }
            let mut e = GzEncoder::new(Vec::new(), Compression::default());
            e.write_all(&serde_json::to_vec(&sub)?)?;
            fs::write(self.chunk_file(chunk_no), e.finish()?)?;
        }
        fs::write(
            self.meta_file(),
            serde_json::to_vec_pretty(&ChunkMeta {
                version: CACHE_VERSION,
                chunk_size: self.chunk_size,
            })?,
        )?;
        self.save_settings_meta(settings_hash)?;
        Ok(())
    }
    pub fn clear_all_settings_caches(&self) -> Result<()> {
        if let Some(base) = self.root.parent() {
            if base.exists() {
                for e in fs::read_dir(base)? {
                    let p = e?.path();
                    if p.is_dir() {
                        fs::remove_dir_all(p)?;
                    }
                }
            }
        }
        self.memory_cache.borrow_mut().clear();
        self.dirty_indexes.borrow_mut().clear();
        Ok(())
    }
    pub fn cleanup_old_caches(&self, keep_dir_name: &str, older_than_secs: u64) -> Result<()> {
        if let Some(base) = self.root.parent() {
            if !base.exists() {
                return Ok(());
            }
            let now = SystemTime::now();
            for e in fs::read_dir(base)? {
                let p = e?.path();
                if !p.is_dir() {
                    continue;
                }
                if p.file_name().and_then(|x| x.to_str()) == Some(keep_dir_name) {
                    continue;
                }
                let m = fs::metadata(&p)?.modified().unwrap_or(now);
                if now.duration_since(m).unwrap_or_default().as_secs() > older_than_secs {
                    fs::remove_dir_all(p)?;
                }
            }
        }
        Ok(())
    }
    pub fn validate_and_repair_cache(&self, expected_settings_hash: &str) -> Result<bool> {
        if self.validate_settings_hash(expected_settings_hash)? {
            return Ok(true);
        }
        if self.root.exists() {
            let _ = fs::remove_dir_all(&self.root);
            fs::create_dir_all(&self.root)?;
        }
        self.memory_cache.borrow_mut().clear();
        self.dirty_indexes.borrow_mut().clear();
        Ok(false)
    }
    fn settings_meta_file(&self) -> PathBuf {
        self.root.join("settings_meta.json")
    }
    fn load_meta(&self) -> Result<Option<CacheMeta>> {
        let p = self.settings_meta_file();
        if !p.exists() {
            return Ok(None);
        }
        Ok(Some(serde_json::from_str(&fs::read_to_string(p)?)?))
    }
    fn save_settings_meta(&self, settings_hash: &str) -> Result<()> {
        fs::write(
            self.settings_meta_file(),
            serde_json::to_vec_pretty(&CacheMeta {
                version: CACHE_VERSION,
                settings_hash: settings_hash.to_string(),
            })?,
        )?;
        Ok(())
    }
    fn clear_chunks(&self) -> Result<()> {
        if !self.root.exists() {
            return Ok(());
        }
        for e in fs::read_dir(&self.root)? {
            let p = e?.path();
            if p.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .starts_with("chunk_")
            {
                fs::remove_file(p)?;
            }
        }
        Ok(())
    }
}
