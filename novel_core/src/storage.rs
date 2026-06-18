use anyhow::{Context, Result};
use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;
use zstd::stream::read::Decoder;

const FAST_ZSTD_LEVEL: i32 = 1;
const ZHTML_DICT_ID_PREFIX: &str = "zhtml";
const ZHTML_DICT_MIN_SAMPLES: usize = 4;
const ZHTML_DICT_MAX_SIZE: usize = 32 * 1024;
const MASTER_DB_NAME: &str = "master.db";
const LEGACY_DB_NAME: &str = "sections.sqlite3";
const NOVELS_DIR_NAME: &str = "novels";
pub const CHAPTERS_PER_SHARD: usize = 1_000;
const DEFAULT_POOL_CAPACITY: usize = 8;

// 32KiB is intentionally larger than SQLite's 4KiB default: compressed NLM/HTML
// chapter BLOBs are usually tens of KiB, so 32KiB reduces overflow pages and
// b-tree fan-out while avoiding the cache waste of 64KiB for many short chapters.
const SQLITE_PAGE_SIZE_BYTES: usize = 32 * 1024;

pub fn compress_zstd(input: &str) -> Result<Vec<u8>> {
    zstd::bulk::compress(input.as_bytes(), FAST_ZSTD_LEVEL)
        .map_err(|e| anyhow::anyhow!("zstd compression failed: {}", e))
}

pub fn decompress_zstd(blob: &[u8]) -> Result<String> {
    let mut decoder = Decoder::new(blob)?;
    let mut decompressed = String::new();
    decoder.read_to_string(&mut decompressed)?;
    Ok(decompressed)
}

pub fn compress_zstd_with_dictionary(input: &str, dictionary: &[u8]) -> Result<Vec<u8>> {
    if dictionary.is_empty() {
        return compress_zstd(input);
    }
    let mut compressor = zstd::bulk::Compressor::with_dictionary(FAST_ZSTD_LEVEL, dictionary)?;
    compressor
        .compress(input.as_bytes())
        .map_err(|e| anyhow::anyhow!("zstd dictionary compression failed: {}", e))
}

pub fn decompress_zstd_with_dictionary(blob: &[u8], dictionary: &[u8]) -> Result<String> {
    if dictionary.is_empty() {
        return decompress_zstd(blob);
    }
    let mut decompressor = zstd::bulk::Decompressor::with_dictionary(dictionary)?;
    let bytes = decompressor
        .decompress(blob, 16 * 1024 * 1024)
        .map_err(|e| anyhow::anyhow!("zstd dictionary decompression failed: {}", e))?;
    String::from_utf8(bytes).map_err(Into::into)
}

pub fn train_zstd_dictionary(samples: &[String], max_size: usize) -> Result<Vec<u8>> {
    if samples.is_empty() || max_size == 0 {
        return Ok(Vec::new());
    }
    let bytes = samples.iter().map(|s| s.as_bytes()).collect::<Vec<_>>();
    zstd::dict::from_samples(&bytes, max_size).map_err(Into::into)
}

/// Returns the master library database path for a download output directory.
///
/// `master.db` is WAL-managed and stores only cross-novel metadata. Chapter
/// bodies are stored in per-novel shards under `novels/<site>/<novel>/0001.db`,
/// `0002.db`, ... with 1,000 chapters per shard.
pub fn library_database_path(output_dir: &Path) -> PathBuf {
    output_dir
        .parent()
        .unwrap_or(output_dir)
        .join(MASTER_DB_NAME)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct NovelListItem {
    pub novel_id: String,
    pub title: String,
    pub author: String,
    pub toc_url: String,
    pub domain: String,
    pub episode_count: usize,
    pub updated_at: String,
    pub output_dir: String,
    pub storage_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredTocChapter {
    pub index: String,
    pub href: String,
    pub subtitle: String,
}

#[derive(Debug, Clone)]
pub struct StoredNovelMetadata {
    pub title: String,
    pub author: String,
}

#[derive(Debug, Clone)]
pub struct SectionUpsert {
    pub novel_id: String,
    pub chapter_index: String,
    pub subtitle: String,
    pub source_url: String,
    pub intro_xhtml: Option<String>,
    pub body_xhtml: String,
    pub post_xhtml: Option<String>,
    pub source_signature: String,
    pub updated_at: String,
}

#[derive(Default)]
struct NovelShardPool {
    capacity: usize,
    entries: HashMap<PathBuf, Connection>,
    lru: VecDeque<PathBuf>,
}

pub struct SectionStorage {
    master_conn: Connection,
    root_dir: PathBuf,
    pool: Mutex<NovelShardPool>,
}

impl SectionStorage {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let master_conn = Connection::open(path)?;
        configure_connection(&master_conn, true)?;
        let this = Self {
            master_conn,
            root_dir: path
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .to_path_buf(),
            pool: Mutex::new(NovelShardPool {
                capacity: DEFAULT_POOL_CAPACITY,
                ..NovelShardPool::default()
            }),
        };
        this.migrate_master()?;
        Ok(this)
    }

    fn migrate_master(&self) -> Result<()> {
        self.master_conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS novels (
                novel_id   TEXT PRIMARY KEY,
                title      TEXT NOT NULL DEFAULT '',
                author     TEXT NOT NULL DEFAULT '',
                toc_url    TEXT NOT NULL DEFAULT '',
                domain     TEXT NOT NULL DEFAULT '',
                output_dir TEXT NOT NULL DEFAULT '',
                shard_dir  TEXT NOT NULL DEFAULT '',
                episode_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT '',
                updated_at TEXT NOT NULL DEFAULT '',
                last_downloaded_at TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_novels_updated ON novels(updated_at DESC, title, novel_id);
            CREATE INDEX IF NOT EXISTS idx_novels_domain ON novels(domain, updated_at DESC);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_novels_toc_url ON novels(toc_url) WHERE toc_url != '';
            "#,
        )?;
        self.add_column_if_missing("novels", "output_dir", "TEXT NOT NULL DEFAULT ''")?;
        self.add_column_if_missing("novels", "shard_dir", "TEXT NOT NULL DEFAULT ''")?;
        self.add_column_if_missing("novels", "created_at", "TEXT NOT NULL DEFAULT ''")?;
        self.add_column_if_missing("novels", "last_downloaded_at", "TEXT NOT NULL DEFAULT ''")?;
        Ok(())
    }

    fn add_column_if_missing(&self, table: &str, column: &str, definition: &str) -> Result<()> {
        let mut stmt = self
            .master_conn
            .prepare(&format!("PRAGMA table_info({table})"))?;
        let columns = stmt.query_map([], |row| row.get::<_, String>(1))?;
        for existing in columns {
            if existing? == column {
                return Ok(());
            }
        }
        self.master_conn.execute(
            &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
            [],
        )?;
        Ok(())
    }

    pub fn page_size_bytes(&self) -> usize {
        SQLITE_PAGE_SIZE_BYTES
    }

    pub fn shard_path_for_chapter(&self, novel_id: &str, chapter_index: &str) -> PathBuf {
        let domain = self
            .domain_for_novel(novel_id)
            .unwrap_or_else(|| domain_from_novel_id(novel_id));
        shard_path(&self.root_dir, &domain, novel_id, chapter_index)
    }

    fn domain_for_novel(&self, novel_id: &str) -> Option<String> {
        self.master_conn
            .query_row(
                "SELECT domain FROM novels WHERE novel_id = ?1",
                params![novel_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .ok()
            .flatten()
            .filter(|domain| !domain.is_empty())
    }

    fn with_shard_connection<T, F>(&self, path: &Path, f: F) -> Result<T>
    where
        F: FnOnce(&mut Connection) -> Result<T>,
    {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut pool = self
            .pool
            .lock()
            .map_err(|_| anyhow::anyhow!("storage pool poisoned"))?;
        if !pool.entries.contains_key(path) {
            while pool.entries.len() >= pool.capacity.max(1) {
                if let Some(victim) = pool.lru.pop_back() {
                    pool.entries.remove(&victim);
                } else {
                    break;
                }
            }
            let conn = Connection::open(path)?;
            configure_connection(&conn, false)?;
            migrate_shard(&conn)?;
            pool.entries.insert(path.to_path_buf(), conn);
        }
        touch_lru(&mut pool.lru, path);
        let conn = pool
            .entries
            .get_mut(path)
            .context("missing shard connection")?;
        f(conn)
    }

    pub fn upsert_novel(
        &self,
        novel_id: &str,
        title: &str,
        author: &str,
        toc_url: &str,
        domain: &str,
        output_dir: &Path,
        episode_count: usize,
        updated_at: &str,
    ) -> Result<()> {
        let output_dir = output_dir.to_string_lossy();
        let shard_dir = novel_shard_dir(&self.root_dir, domain, novel_id)
            .to_string_lossy()
            .into_owned();
        self.master_conn.execute(
            r#"INSERT INTO novels
                   (novel_id, title, author, toc_url, domain, output_dir, shard_dir, episode_count,
                    created_at, updated_at, last_downloaded_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?9)
               ON CONFLICT(novel_id) DO UPDATE SET
                 title              = CASE WHEN excluded.title != '' THEN excluded.title ELSE novels.title END,
                 author             = CASE WHEN excluded.author != '' THEN excluded.author ELSE novels.author END,
                 toc_url            = excluded.toc_url,
                 domain             = excluded.domain,
                 output_dir         = excluded.output_dir,
                 shard_dir          = excluded.shard_dir,
                 episode_count      = excluded.episode_count,
                 updated_at         = excluded.updated_at,
                 last_downloaded_at = excluded.last_downloaded_at"#,
            params![novel_id, title, author, toc_url, domain, output_dir.as_ref(), shard_dir, episode_count as i64, updated_at],
        )?;
        Ok(())
    }

    pub fn upsert_section(
        &self,
        novel_id: &str,
        chapter_index: &str,
        subtitle: &str,
        source_url: &str,
        intro_xhtml: Option<&str>,
        body_xhtml: &str,
        post_xhtml: Option<&str>,
        source_signature: &str,
        updated_at: &str,
    ) -> Result<()> {
        self.upsert_sections(&[SectionUpsert {
            novel_id: novel_id.to_string(),
            chapter_index: chapter_index.to_string(),
            subtitle: subtitle.to_string(),
            source_url: source_url.to_string(),
            intro_xhtml: intro_xhtml.map(ToOwned::to_owned),
            body_xhtml: body_xhtml.to_string(),
            post_xhtml: post_xhtml.map(ToOwned::to_owned),
            source_signature: source_signature.to_string(),
            updated_at: updated_at.to_string(),
        }])
    }

    pub fn upsert_sections(&self, sections: &[SectionUpsert]) -> Result<()> {
        let mut grouped: HashMap<PathBuf, Vec<&SectionUpsert>> = HashMap::new();
        for section in sections {
            grouped
                .entry(self.shard_path_for_chapter(&section.novel_id, &section.chapter_index))
                .or_default()
                .push(section);
        }
        for (path, batch) in grouped {
            self.with_shard_connection(&path, |conn| {
                let tx = conn.transaction()?;
                write_section_batch(&tx, &batch)?;
                tx.commit()?;
                Ok(())
            })?;
        }
        Ok(())
    }

    pub fn upsert_section_placeholder(
        &self,
        novel_id: &str,
        chapter_index: &str,
        subtitle: &str,
        source_url: &str,
        updated_at: &str,
    ) -> Result<()> {
        self.upsert_section_placeholders(
            novel_id,
            &[StoredTocChapter {
                index: chapter_index.to_string(),
                href: source_url.to_string(),
                subtitle: subtitle.to_string(),
            }],
            updated_at,
        )
    }

    pub fn upsert_section_placeholders(
        &self,
        novel_id: &str,
        chapters: &[StoredTocChapter],
        updated_at: &str,
    ) -> Result<()> {
        let mut grouped: HashMap<PathBuf, Vec<&StoredTocChapter>> = HashMap::new();
        for chapter in chapters {
            grouped
                .entry(self.shard_path_for_chapter(novel_id, &chapter.index))
                .or_default()
                .push(chapter);
        }
        let empty_body = compress_zstd("")?;
        for (path, batch) in grouped {
            self.with_shard_connection(&path, |conn| {
                let tx = conn.transaction()?;
                write_placeholder_batch(&tx, novel_id, &batch, &empty_body, updated_at)?;
                tx.commit()?;
                Ok(())
            })?;
        }
        Ok(())
    }

    pub fn novel_metadata(&self, novel_id: &str) -> Result<Option<StoredNovelMetadata>> {
        let mut stmt = self
            .master_conn
            .prepare("SELECT title, author FROM novels WHERE novel_id = ?1")?;
        let mut rows = stmt.query(params![novel_id])?;
        if let Some(row) = rows.next()? {
            Ok(Some(StoredNovelMetadata {
                title: row.get(0)?,
                author: row.get(1)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn cached_toc_chapters(&self, novel_id: &str) -> Result<Vec<StoredTocChapter>> {
        let paths = self.shard_paths_for_novel(novel_id)?;
        let mut chapters = Vec::new();
        for path in paths {
            self.with_shard_connection(&path, |conn| {
                let mut stmt = conn.prepare(
                    r#"SELECT chapter_index, source_url, subtitle
                       FROM sections
                       WHERE novel_id = ?1 AND source_url != ''
                       ORDER BY sort_key, chapter_index"#,
                )?;
                let rows = stmt.query_map(params![novel_id], |row| {
                    Ok(StoredTocChapter {
                        index: row.get(0)?,
                        href: row.get(1)?,
                        subtitle: row.get(2)?,
                    })
                })?;
                for row in rows {
                    chapters.push(row?);
                }
                Ok(())
            })?;
        }
        chapters.sort_by(|a, b| {
            section_sort_key(&a.index)
                .total_cmp(&section_sort_key(&b.index))
                .then_with(|| a.index.cmp(&b.index))
        });
        Ok(chapters)
    }

    pub fn section_download_state(
        &self,
        novel_id: &str,
        chapter_index: &str,
    ) -> Result<Option<(String, bool)>> {
        let path = self.shard_path_for_chapter(novel_id, chapter_index);
        if !path.exists() {
            return Ok(None);
        }
        self.with_shard_connection(&path, |conn| {
            conn.query_row(
                "SELECT source_signature, body_downloaded FROM sections WHERE novel_id = ?1 AND chapter_index = ?2",
                params![novel_id, chapter_index],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? != 0)),
            ).optional().map_err(Into::into)
        })
    }

    pub fn section_source_signature(
        &self,
        novel_id: &str,
        chapter_index: &str,
    ) -> Result<Option<String>> {
        Ok(self
            .section_download_state(novel_id, chapter_index)?
            .map(|(signature, _)| signature))
    }

    pub fn section_download_states(
        &self,
        novel_id: &str,
    ) -> Result<HashMap<String, (String, bool)>> {
        let mut states = HashMap::new();
        for path in self.shard_paths_for_novel(novel_id)? {
            self.with_shard_connection(&path, |conn| {
                let mut stmt = conn.prepare(
                    "SELECT chapter_index, source_signature, body_downloaded FROM sections WHERE novel_id = ?1",
                )?;
                let rows = stmt.query_map(params![novel_id], |row| {
                    Ok((row.get::<_, String>(0)?, (row.get::<_, String>(1)?, row.get::<_, i64>(2)? != 0)))
                })?;
                for row in rows {
                    let (chapter_index, state) = row?;
                    states.insert(chapter_index, state);
                }
                Ok(())
            })?;
        }
        Ok(states)
    }

    pub fn list_novels(
        &self,
        fallback_output_dir: &Path,
        storage_path: &Path,
    ) -> Result<Vec<NovelListItem>> {
        list_novels_from_connection(&self.master_conn, fallback_output_dir, storage_path)
    }

    pub fn list_novels_in_existing_db(
        path: &Path,
        output_dir: &Path,
    ) -> Result<Vec<NovelListItem>> {
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        conn.busy_timeout(Duration::from_secs(30))?;
        list_novels_from_connection(&conn, output_dir, path)
    }

    fn shard_paths_for_novel(&self, novel_id: &str) -> Result<Vec<PathBuf>> {
        let domain = self
            .domain_for_novel(novel_id)
            .unwrap_or_else(|| domain_from_novel_id(novel_id));
        let dir = novel_shard_dir(&self.root_dir, &domain, novel_id);
        if !dir.is_dir() {
            return Ok(Vec::new());
        }
        let mut paths = Vec::new();
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) == Some("db") {
                paths.push(path);
            }
        }
        paths.sort();
        Ok(paths)
    }
}

fn configure_connection(conn: &Connection, master: bool) -> Result<()> {
    conn.busy_timeout(Duration::from_secs(30))?;
    conn.execute_batch(&format!(
        "PRAGMA page_size={}; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=30000; PRAGMA temp_store=MEMORY; PRAGMA mmap_size=268435456; PRAGMA cache_size=-32768;{}",
        SQLITE_PAGE_SIZE_BYTES,
        if master { " PRAGMA wal_autocheckpoint=1000;" } else { " PRAGMA wal_autocheckpoint=4000;" }
    ))?;
    Ok(())
}

fn migrate_shard(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS sections (
            novel_id          TEXT NOT NULL,
            chapter_index     TEXT NOT NULL,
            sort_key          REAL NOT NULL DEFAULT 0,
            subtitle          TEXT NOT NULL,
            source_url        TEXT NOT NULL DEFAULT '',
            intro_xhtml_zstd  BLOB,
            body_xhtml_zstd   BLOB NOT NULL,
            post_xhtml_zstd   BLOB,
            intro_zstd_dict_id TEXT,
            body_zstd_dict_id  TEXT,
            post_zstd_dict_id  TEXT,
            markup_format     TEXT NOT NULL DEFAULT 'xhtml_subset',
            source_signature  TEXT NOT NULL DEFAULT '',
            body_downloaded   INTEGER NOT NULL DEFAULT 0,
            updated_at        TEXT NOT NULL,
            PRIMARY KEY (novel_id, chapter_index)
        );
        CREATE TABLE IF NOT EXISTS zstd_dictionaries (
            novel_id      TEXT NOT NULL,
            dict_id       TEXT NOT NULL,
            dictionary    BLOB NOT NULL,
            sample_count  INTEGER NOT NULL DEFAULT 0,
            trained_at    TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (novel_id, dict_id)
        );
        CREATE TABLE IF NOT EXISTS images (
            novel_id      TEXT NOT NULL,
            image_id      INTEGER NOT NULL,
            mime_type     TEXT NOT NULL DEFAULT '',
            width         INTEGER NOT NULL DEFAULT 0,
            height        INTEGER NOT NULL DEFAULT 0,
            image_zstd    BLOB NOT NULL,
            updated_at    TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (novel_id, image_id)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS sections_fts USING fts5(
            novel_id UNINDEXED, chapter_index UNINDEXED, subtitle, body_text, content=''
        );
        CREATE INDEX IF NOT EXISTS idx_sections_novel_sort ON sections(novel_id, sort_key, chapter_index);
        CREATE INDEX IF NOT EXISTS idx_sections_novel_source_url ON sections(novel_id, source_url);
        "#,
    )?;
    add_shard_column_if_missing(conn, "sections", "sort_key", "REAL NOT NULL DEFAULT 0")?;
    add_shard_column_if_missing(conn, "sections", "source_url", "TEXT NOT NULL DEFAULT ''")?;
    add_shard_column_if_missing(conn, "sections", "intro_zstd_dict_id", "TEXT")?;
    add_shard_column_if_missing(conn, "sections", "body_zstd_dict_id", "TEXT")?;
    add_shard_column_if_missing(conn, "sections", "post_zstd_dict_id", "TEXT")?;
    add_shard_column_if_missing(
        conn,
        "sections",
        "markup_format",
        "TEXT NOT NULL DEFAULT 'xhtml_subset'",
    )?;
    add_shard_column_if_missing(
        conn,
        "sections",
        "source_signature",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    add_shard_column_if_missing(
        conn,
        "sections",
        "body_downloaded",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    Ok(())
}

fn add_shard_column_if_missing(
    conn: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = stmt.query_map([], |row| row.get::<_, String>(1))?;
    for existing in columns {
        if existing? == column {
            return Ok(());
        }
    }
    conn.execute(
        &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
        [],
    )?;
    Ok(())
}

fn train_batch_zhtml_dictionary(
    tx: &Transaction<'_>,
    sections: &[&SectionUpsert],
) -> Result<Option<(String, Vec<u8>)>> {
    let samples = sections
        .iter()
        .flat_map(|section| {
            [
                section.intro_xhtml.as_ref(),
                Some(&section.body_xhtml),
                section.post_xhtml.as_ref(),
            ]
        })
        .filter_map(|value| value.filter(|text| !text.trim().is_empty()).cloned())
        .collect::<Vec<_>>();

    if samples.len() < ZHTML_DICT_MIN_SAMPLES {
        return Ok(None);
    }
    let dictionary = match train_zstd_dictionary(&samples, ZHTML_DICT_MAX_SIZE) {
        Ok(dictionary) if !dictionary.is_empty() => dictionary,
        Ok(_) | Err(_) => return Ok(None),
    };
    let digest = Sha256::digest(&dictionary);
    let suffix = digest[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let dict_id = format!("{ZHTML_DICT_ID_PREFIX}-{suffix}");
    let novel_id = &sections[0].novel_id;
    tx.execute(
        "INSERT INTO zstd_dictionaries(novel_id, dict_id, dictionary, sample_count, trained_at)
         VALUES(?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(novel_id, dict_id) DO UPDATE SET
           sample_count = excluded.sample_count, trained_at = excluded.trained_at",
        params![
            novel_id,
            &dict_id,
            &dictionary,
            samples.len() as i64,
            chrono::Utc::now().to_rfc3339()
        ],
    )?;
    Ok(Some((dict_id, dictionary)))
}

fn compress_maybe_with_dictionary(
    input: Option<&str>,
    dictionary: Option<&[u8]>,
) -> Result<Option<Vec<u8>>> {
    input
        .map(|text| compress_zhtml_component(text, dictionary))
        .transpose()
}

fn compress_zhtml_component(input: &str, dictionary: Option<&[u8]>) -> Result<Vec<u8>> {
    match dictionary {
        Some(dictionary) => compress_zstd_with_dictionary(input, dictionary),
        None => compress_zstd(input),
    }
}

fn write_section_batch(tx: &Transaction<'_>, sections: &[&SectionUpsert]) -> Result<()> {
    let dictionary_entry = train_batch_zhtml_dictionary(tx, sections)?;
    let dictionary_id = dictionary_entry
        .as_ref()
        .map(|(dict_id, _)| dict_id.as_str());
    let dictionary = dictionary_entry
        .as_ref()
        .map(|(_, dictionary)| dictionary.as_slice());
    let mut upsert_stmt = tx.prepare(
        r#"INSERT INTO sections
               (novel_id, chapter_index, sort_key, subtitle, source_url,
                intro_xhtml_zstd, body_xhtml_zstd, post_xhtml_zstd,
                intro_zstd_dict_id, body_zstd_dict_id, post_zstd_dict_id, markup_format,
                source_signature, body_downloaded, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'xhtml_subset', ?12, 1, ?13)
           ON CONFLICT(novel_id, chapter_index) DO UPDATE SET
             sort_key         = excluded.sort_key,
             subtitle         = excluded.subtitle,
             source_url       = CASE WHEN excluded.source_url != '' THEN excluded.source_url ELSE sections.source_url END,
             intro_xhtml_zstd = excluded.intro_xhtml_zstd,
             body_xhtml_zstd  = excluded.body_xhtml_zstd,
             post_xhtml_zstd  = excluded.post_xhtml_zstd,
             intro_zstd_dict_id = excluded.intro_zstd_dict_id,
             body_zstd_dict_id  = excluded.body_zstd_dict_id,
             post_zstd_dict_id  = excluded.post_zstd_dict_id,
             markup_format    = excluded.markup_format,
             source_signature = CASE WHEN excluded.source_signature != '' THEN excluded.source_signature ELSE sections.source_signature END,
             body_downloaded  = 1,
             updated_at       = excluded.updated_at"#,
    )?;
    let mut delete_fts_stmt =
        tx.prepare("DELETE FROM sections_fts WHERE novel_id = ?1 AND chapter_index = ?2")?;
    let mut insert_fts_stmt = tx.prepare(
        "INSERT INTO sections_fts(novel_id, chapter_index, subtitle, body_text) VALUES(?1, ?2, ?3, ?4)",
    )?;
    for section in sections {
        let intro_blob =
            compress_maybe_with_dictionary(section.intro_xhtml.as_deref(), dictionary)?;
        let body_blob = compress_zhtml_component(&section.body_xhtml, dictionary)?;
        let post_blob = compress_maybe_with_dictionary(section.post_xhtml.as_deref(), dictionary)?;
        let intro_dict_id = section.intro_xhtml.as_ref().and(dictionary_id);
        let body_dict_id = dictionary_id;
        let post_dict_id = section.post_xhtml.as_ref().and(dictionary_id);
        upsert_stmt.execute(params![
            &section.novel_id,
            &section.chapter_index,
            section_sort_key(&section.chapter_index),
            &section.subtitle,
            &section.source_url,
            intro_blob,
            body_blob,
            post_blob,
            intro_dict_id,
            body_dict_id,
            post_dict_id,
            &section.source_signature,
            &section.updated_at,
        ])?;
        let searchable = [
            section.intro_xhtml.as_deref().unwrap_or(""),
            &section.body_xhtml,
            section.post_xhtml.as_deref().unwrap_or(""),
        ]
        .join("\n");
        delete_fts_stmt.execute(params![&section.novel_id, &section.chapter_index])?;
        insert_fts_stmt.execute(params![
            &section.novel_id,
            &section.chapter_index,
            &section.subtitle,
            searchable
        ])?;
    }
    Ok(())
}

fn write_placeholder_batch(
    tx: &Transaction<'_>,
    novel_id: &str,
    chapters: &[&StoredTocChapter],
    empty_body: &[u8],
    updated_at: &str,
) -> Result<()> {
    let mut upsert_stmt = tx.prepare(
        r#"INSERT INTO sections
               (novel_id, chapter_index, sort_key, subtitle, source_url,
                intro_xhtml_zstd, body_xhtml_zstd, post_xhtml_zstd,
                intro_zstd_dict_id, body_zstd_dict_id, post_zstd_dict_id,
                source_signature, body_downloaded, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, NULL, NULL, NULL, '', 0, ?7)
           ON CONFLICT(novel_id, chapter_index) DO UPDATE SET
             sort_key   = excluded.sort_key,
             subtitle   = excluded.subtitle,
             source_url = CASE WHEN excluded.source_url != '' THEN excluded.source_url ELSE sections.source_url END,
             body_downloaded = CASE WHEN sections.source_signature = '' THEN 0 ELSE sections.body_downloaded END,
             updated_at = CASE WHEN sections.source_signature = '' THEN excluded.updated_at ELSE sections.updated_at END"#,
    )?;
    let mut delete_fts_stmt = tx.prepare("DELETE FROM sections_fts WHERE novel_id = ?1 AND chapter_index = ?2 AND EXISTS (SELECT 1 FROM sections WHERE novel_id = ?1 AND chapter_index = ?2 AND source_signature = '')")?;
    let mut insert_fts_stmt = tx.prepare("INSERT INTO sections_fts(novel_id, chapter_index, subtitle, body_text) SELECT novel_id, chapter_index, subtitle, '' FROM sections WHERE novel_id = ?1 AND chapter_index = ?2 AND source_signature = ''")?;
    for chapter in chapters {
        upsert_stmt.execute(params![
            novel_id,
            &chapter.index,
            section_sort_key(&chapter.index),
            &chapter.subtitle,
            &chapter.href,
            empty_body,
            updated_at
        ])?;
        delete_fts_stmt.execute(params![novel_id, &chapter.index])?;
        insert_fts_stmt.execute(params![novel_id, &chapter.index])?;
    }
    Ok(())
}

fn touch_lru(lru: &mut VecDeque<PathBuf>, path: &Path) {
    if let Some(pos) = lru.iter().position(|p| p == path) {
        lru.remove(pos);
    }
    lru.push_front(path.to_path_buf());
}

fn novel_shard_dir(root_dir: &Path, domain: &str, novel_id: &str) -> PathBuf {
    root_dir
        .join(NOVELS_DIR_NAME)
        .join(safe_path_component(domain))
        .join(safe_path_component(novel_id))
}

fn shard_path(root_dir: &Path, domain: &str, novel_id: &str, chapter_index: &str) -> PathBuf {
    novel_shard_dir(root_dir, domain, novel_id)
        .join(format!("{:04}.db", shard_number(chapter_index)))
}

fn shard_number(chapter_index: &str) -> usize {
    let digits = chapter_index
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>();
    let value = digits.parse::<usize>().unwrap_or(1).max(1);
    ((value - 1) / CHAPTERS_PER_SHARD) + 1
}

fn domain_from_novel_id(novel_id: &str) -> String {
    novel_id.split(':').next().unwrap_or("unknown").to_string()
}

fn safe_path_component(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'.' | b'_' | b'-' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    if out.is_empty() {
        let mut hasher = Sha256::new();
        hasher.update(input.as_bytes());
        format!("novel-{:x}", hasher.finalize())
    } else {
        out
    }
}

pub fn section_sort_key(chapter_index: &str) -> f64 {
    chapter_index.parse::<f64>().unwrap_or_else(|_| {
        let mut hasher = Sha256::new();
        hasher.update(chapter_index.as_bytes());
        let hash = hasher.finalize();
        let bytes: [u8; 8] = hash[..8].try_into().unwrap_or([0; 8]);
        u64::from_be_bytes(bytes) as f64
    })
}

fn list_novels_from_connection(
    conn: &Connection,
    fallback_output_dir: &Path,
    storage_path: &Path,
) -> Result<Vec<NovelListItem>> {
    let has_shard_dir = table_has_column(conn, "novels", "shard_dir")?;
    let output_expr = if table_has_column(conn, "novels", "output_dir")? {
        "output_dir"
    } else {
        "''"
    };
    let shard_expr = if has_shard_dir { "shard_dir" } else { "''" };
    let sql = format!(
        r#"SELECT novel_id, title, author, toc_url, domain, episode_count, updated_at, {output_expr}, {shard_expr}
           FROM novels
           ORDER BY updated_at DESC, title ASC, novel_id ASC"#
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        let episode_count: i64 = row.get(5)?;
        let output_dir: String = row.get(7)?;
        Ok(NovelListItem {
            novel_id: row.get(0)?,
            title: row.get(1)?,
            author: row.get(2)?,
            toc_url: row.get(3)?,
            domain: row.get(4)?,
            episode_count: episode_count.max(0) as usize,
            updated_at: row.get(6)?,
            output_dir: if output_dir.is_empty() {
                fallback_output_dir.to_string_lossy().into_owned()
            } else {
                output_dir
            },
            storage_path: storage_path.to_string_lossy().into_owned(),
        })
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(Into::into)
}

fn table_has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = stmt.query_map([], |row| row.get::<_, String>(1))?;
    for existing in columns {
        if existing? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

pub fn discover_downloaded_novels(root_dir: &Path) -> Result<Vec<NovelListItem>> {
    let master_db = root_dir.join(MASTER_DB_NAME);
    let legacy_root_db = root_dir.join(LEGACY_DB_NAME);
    let mut items = Vec::new();

    if master_db.is_file() {
        items.extend(SectionStorage::list_novels_in_existing_db(
            &master_db, root_dir,
        )?);
    }
    if legacy_root_db.is_file() {
        items.extend(SectionStorage::list_novels_in_existing_db(
            &legacy_root_db,
            root_dir,
        )?);
    }

    if root_dir.is_dir() {
        for entry in std::fs::read_dir(root_dir)? {
            let entry = entry?;
            if !entry.file_type().map(|ft| ft.is_dir()).unwrap_or(false) {
                continue;
            }
            let output_dir = entry.path();
            for db_name in [MASTER_DB_NAME, LEGACY_DB_NAME] {
                let db_path = output_dir.join(db_name);
                if db_path.is_file() {
                    if let Ok(mut novels) =
                        SectionStorage::list_novels_in_existing_db(&db_path, &output_dir)
                    {
                        items.append(&mut novels);
                    }
                }
            }
        }
    }

    items.sort_by(|a, b| {
        let a_is_master = a.storage_path == master_db.to_string_lossy();
        let b_is_master = b.storage_path == master_db.to_string_lossy();
        b_is_master
            .cmp(&a_is_master)
            .then_with(|| b.updated_at.cmp(&a.updated_at))
            .then_with(|| a.title.cmp(&b.title))
            .then_with(|| a.novel_id.cmp(&b.novel_id))
    });
    let mut seen_keys = std::collections::HashSet::new();
    items.retain(|item| {
        let key = if item.toc_url.is_empty() {
            item.novel_id.clone()
        } else {
            item.toc_url.clone()
        };
        seen_keys.insert(key)
    });
    items.sort_by(|a, b| {
        b.updated_at
            .cmp(&a.updated_at)
            .then_with(|| a.title.cmp(&b.title))
            .then_with(|| a.novel_id.cmp(&b.novel_id))
    });
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("novel_core_storage_{name}_{unique}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn library_database_path_points_to_master_at_library_root() {
        let root = temp_dir("library_path");
        let output_dir = root.join("example-novel");
        assert_eq!(library_database_path(&output_dir), root.join("master.db"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn master_database_stores_metadata_and_shards_store_sections() {
        let root = temp_dir("shards");
        let db_path = root.join("master.db");
        let storage = SectionStorage::open(&db_path).unwrap();
        let output_dir = root.join("out");
        let novel_id = "example.com:/works/1";
        storage
            .upsert_novel(
                novel_id,
                "Example",
                "Author",
                "https://example.com/works/1",
                "example.com",
                &output_dir,
                2,
                "2026-05-28T00:00:00Z",
            )
            .unwrap();
        storage
            .upsert_sections(&[
                SectionUpsert {
                    novel_id: novel_id.to_string(),
                    chapter_index: "1".to_string(),
                    subtitle: "Chapter 1".to_string(),
                    source_url: "chapter-1".to_string(),
                    intro_xhtml: None,
                    body_xhtml: "<p>body</p>".to_string(),
                    post_xhtml: None,
                    source_signature: "sig-a".to_string(),
                    updated_at: "2026-05-28T00:00:01Z".to_string(),
                },
                SectionUpsert {
                    novel_id: novel_id.to_string(),
                    chapter_index: "1001".to_string(),
                    subtitle: "Chapter 1001".to_string(),
                    source_url: "chapter-1001".to_string(),
                    intro_xhtml: None,
                    body_xhtml: "<p>body</p>".to_string(),
                    post_xhtml: None,
                    source_signature: "sig-b".to_string(),
                    updated_at: "2026-05-28T00:00:02Z".to_string(),
                },
            ])
            .unwrap();
        assert!(root.join("master.db").is_file());
        assert!(
            storage
                .shard_path_for_chapter(novel_id, "1")
                .ends_with("0001.db")
        );
        assert!(
            storage
                .shard_path_for_chapter(novel_id, "1001")
                .ends_with("0002.db")
        );
        let master_conn = Connection::open(root.join("master.db")).unwrap();
        let section_tables: i64 = master_conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = 'sections'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(section_tables, 0);
        assert_eq!(
            storage.section_download_state(novel_id, "1").unwrap(),
            Some(("sig-a".to_string(), true))
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn placeholder_batch_preserves_download_state() {
        let root = temp_dir("download_state");
        let db_path = root.join("master.db");
        let storage = SectionStorage::open(&db_path).unwrap();
        let novel_id = "example.com:/works/1";
        storage
            .upsert_novel(
                novel_id,
                "Example",
                "Author",
                "https://example.com/works/1",
                "example.com",
                &root.join("out"),
                1,
                "2026-05-28T00:00:00Z",
            )
            .unwrap();
        storage
            .upsert_section_placeholder(
                novel_id,
                "1",
                "Chapter 1",
                "chapter-1",
                "2026-05-28T00:00:00Z",
            )
            .unwrap();
        assert_eq!(
            storage.section_download_state(novel_id, "1").unwrap(),
            Some(("".to_string(), false))
        );
        storage
            .upsert_section(
                novel_id,
                "1",
                "Chapter 1",
                "chapter-1",
                None,
                "<p>body</p>",
                None,
                "sig-a",
                "2026-05-28T00:00:01Z",
            )
            .unwrap();
        storage
            .upsert_section_placeholder(
                novel_id,
                "1",
                "Chapter 1",
                "chapter-1",
                "2026-05-28T00:00:02Z",
            )
            .unwrap();
        assert_eq!(
            storage.section_download_state(novel_id, "1").unwrap(),
            Some(("sig-a".to_string(), true))
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn root_database_lists_multiple_novels_with_distinct_output_dirs() {
        let root = temp_dir("multi");
        let db_path = root.join("master.db");
        let storage = SectionStorage::open(&db_path).unwrap();
        let first_dir = root.join("first");
        let second_dir = root.join("second");
        storage
            .upsert_novel(
                "example.com:/works/1",
                "First",
                "Author A",
                "https://example.com/works/1",
                "example.com",
                &first_dir,
                1,
                "2026-05-28T00:00:00Z",
            )
            .unwrap();
        storage
            .upsert_novel(
                "example.com:/works/2",
                "Second",
                "Author B",
                "https://example.com/works/2",
                "example.com",
                &second_dir,
                2,
                "2026-05-28T00:00:02Z",
            )
            .unwrap();
        drop(storage);
        let novels = discover_downloaded_novels(&root).unwrap();
        assert_eq!(novels.len(), 2);
        assert!(
            novels
                .iter()
                .all(|novel| novel.storage_path == db_path.to_string_lossy())
        );
        assert!(
            novels
                .iter()
                .any(|novel| novel.title == "First" && novel.episode_count == 1)
        );
        assert!(novels.iter().any(
            |novel| novel.title == "Second" && novel.output_dir == second_dir.to_string_lossy()
        ));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn list_novels_reads_legacy_schema_without_migrating() {
        let root = temp_dir("readonly_legacy_list");
        let db_path = root.join("sections.sqlite3");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE novels (
                novel_id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                author TEXT NOT NULL DEFAULT '',
                toc_url TEXT NOT NULL DEFAULT '',
                domain TEXT NOT NULL DEFAULT '',
                episode_count INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL DEFAULT ''
            );
            INSERT INTO novels
                (novel_id, title, author, toc_url, domain, episode_count, updated_at)
            VALUES
                ('legacy:/n1', 'Legacy Novel', 'Author', 'https://example.com/n1', 'example.com', 9, '2026-05-30');
            "#,
        ).unwrap();
        drop(conn);
        let novels = SectionStorage::list_novels_in_existing_db(&db_path, &root).unwrap();
        assert_eq!(novels.len(), 1);
        assert_eq!(novels[0].episode_count, 9);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn zstd_dictionary_round_trips_nlm_like_text() {
        let samples = vec!["《漢字|かんじ》\n〃強調〃\n[img:3:640:480]".to_string(); 8];
        let dict = train_zstd_dictionary(&samples, 1024).unwrap();
        let input = "通常テキスト\n\n《漢字|かんじ》と＊太字＊---";
        let compressed = compress_zstd_with_dictionary(input, &dict).unwrap();
        assert_eq!(
            decompress_zstd_with_dictionary(&compressed, &dict).unwrap(),
            input
        );
    }
}
