// nc_storage.cpp — SQLite master + zstd-compressed sharded sections.
// Schema-compatible with the previous Rust implementation (storage.rs);
// zstd dictionary *training* is intentionally dropped (only decoding of older
// dictionary blobs is kept) as part of the port consolidation.
#include "nc_storage.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <mutex>
#include <sqlite3.h>
#if defined(NC_HAVE_ZSTD)
#include <zstd.h>
#endif

namespace fs = std::filesystem;

namespace nc {

namespace {

const int kFastZstdLevel = 1;
const char* kMasterDbName = "master.db";
const char* kLegacyDbName = "sections.sqlite3";
const char* kNovelsDirName = "novels";
const size_t kChaptersPerShard = 1000;
const int kSqlitePageSize = 32 * 1024;

struct Sqlite {
    sqlite3* db = nullptr;
    Sqlite() = default;
    explicit Sqlite(const std::string& path) {
        if (sqlite3_open_v2(path.c_str(), &db,
                            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                            nullptr) != SQLITE_OK) {
            std::string msg = db ? sqlite3_errmsg(db) : "open failed";
            if (db) sqlite3_close(db);
            db = nullptr;
            throw Error("sqlite open: " + msg + " (" + path + ")");
        }
    }
    ~Sqlite() {
        if (db) sqlite3_close(db);
    }
    Sqlite(Sqlite&& o) noexcept : db(o.db) { o.db = nullptr; }
    Sqlite& operator=(Sqlite&& o) noexcept {
        if (this != &o) {
            if (db) sqlite3_close(db);
            db = o.db;
            o.db = nullptr;
        }
        return *this;
    }
    Sqlite(const Sqlite&) = delete;

    void exec(const std::string& sql) {
        char* err = nullptr;
        if (sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &err) != SQLITE_OK) {
            std::string msg = err ? err : "exec failed";
            sqlite3_free(err);
            throw Error("sqlite: " + msg);
        }
    }
    sqlite3_stmt* prepare(const std::string& sql) {
        sqlite3_stmt* stmt = nullptr;
        if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK)
            throw Error(std::string("sqlite prepare: ") + sqlite3_errmsg(db) + " [" + sql + "]");
        return stmt;
    }
};

struct Stmt {
    sqlite3_stmt* s = nullptr;
    explicit Stmt(sqlite3_stmt* stmt) : s(stmt) {}
    ~Stmt() {
        if (s) sqlite3_finalize(s);
    }
    Stmt(const Stmt&) = delete;
    void bind_text(int idx, const std::string& v) {
        sqlite3_bind_text(s, idx, v.c_str(), (int)v.size(), SQLITE_TRANSIENT);
    }
    void bind_blob(int idx, const std::string& v) {
        sqlite3_bind_blob(s, idx, v.data(), (int)v.size(), SQLITE_TRANSIENT);
    }
    void bind_int64(int idx, long long v) { sqlite3_bind_int64(s, idx, v); }
    void bind_double(int idx, double v) { sqlite3_bind_double(s, idx, v); }
    void bind_null(int idx) { sqlite3_bind_null(s, idx); }
    bool step() {
        int rc = sqlite3_step(s);
        if (rc == SQLITE_ROW) return true;
        if (rc == SQLITE_DONE) return false;
        throw Error(std::string("sqlite step: ") + sqlite3_errmsg(sqlite3_db_handle(s)));
    }
    void reset() {
        sqlite3_reset(s);
        sqlite3_clear_bindings(s);
    }
    std::string col_text(int idx) {
        const unsigned char* p = sqlite3_column_text(s, idx);
        return p ? (const char*)p : "";
    }
    std::string col_blob(int idx) {
        const void* p = sqlite3_column_blob(s, idx);
        int n = sqlite3_column_bytes(s, idx);
        return p ? std::string((const char*)p, (size_t)n) : std::string();
    }
    long long col_int64(int idx) { return sqlite3_column_int64(s, idx); }
    double col_double(int idx) { return sqlite3_column_double(s, idx); }
    bool col_null(int idx) { return sqlite3_column_type(s, idx) == SQLITE_NULL; }
};

void configure_connection(Sqlite& db, bool master) {
    db.exec("PRAGMA page_size=" + std::to_string(kSqlitePageSize) +
            "; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=30000;"
            " PRAGMA temp_store=MEMORY; PRAGMA mmap_size=268435456; PRAGMA cache_size=-32768;" +
            std::string(master ? " PRAGMA wal_autocheckpoint=1000;"
                               : " PRAGMA wal_autocheckpoint=4000;"));
}

bool table_has_column(Sqlite& db, const std::string& table, const std::string& column) {
    Stmt stmt(db.prepare("PRAGMA table_info(" + table + ")"));
    while (stmt.step())
        if (stmt.col_text(1) == column) return true;
    return false;
}

void add_column_if_missing(Sqlite& db, const std::string& table, const std::string& column,
                           const std::string& definition) {
    if (table_has_column(db, table, column)) return;
    db.exec("ALTER TABLE " + table + " ADD COLUMN " + column + " " + definition);
}

void migrate_master(Sqlite& db) {
    db.exec(R"SQL(
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
    )SQL");
    add_column_if_missing(db, "novels", "output_dir", "TEXT NOT NULL DEFAULT ''");
    add_column_if_missing(db, "novels", "shard_dir", "TEXT NOT NULL DEFAULT ''");
    add_column_if_missing(db, "novels", "description", "TEXT NOT NULL DEFAULT ''");
    add_column_if_missing(db, "novels", "created_at", "TEXT NOT NULL DEFAULT ''");
    add_column_if_missing(db, "novels", "last_downloaded_at", "TEXT NOT NULL DEFAULT ''");
}

void migrate_shard(Sqlite& db) {
    db.exec(R"SQL(
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
            image_key     TEXT NOT NULL,
            content_type  TEXT NOT NULL DEFAULT '',
            data          BLOB NOT NULL,
            updated_at    TEXT NOT NULL,
            PRIMARY KEY (novel_id, image_key)
        );
        CREATE INDEX IF NOT EXISTS idx_sections_novel_sort ON sections(novel_id, sort_key, chapter_index);
        CREATE INDEX IF NOT EXISTS idx_sections_novel_source_url ON sections(novel_id, source_url);
    )SQL");
    // FTS5 when available; plain table fallback keeps portability.
    try {
        db.exec(R"SQL(
            CREATE VIRTUAL TABLE IF NOT EXISTS sections_fts USING fts5(
                novel_id UNINDEXED, chapter_index UNINDEXED, subtitle, body_text);
        )SQL");
    } catch (...) {
        try {
            db.exec(R"SQL(
                CREATE TABLE IF NOT EXISTS sections_fts (
                    novel_id TEXT, chapter_index TEXT, subtitle TEXT, body_text TEXT);
            )SQL");
        } catch (...) {
        }
    }
}

std::string safe_path_component(const std::string& input) {
    std::string out;
    for (unsigned char byte : input) {
        if (std::isalnum(byte) || byte == '.' || byte == '_' || byte == '-') {
            out.push_back((char)byte);
        } else {
            char buf[8];
            std::snprintf(buf, sizeof buf, "%%%02X", byte);
            out += buf;
        }
    }
    return out.empty() ? "novel-empty" : out;
}


size_t shard_number(const std::string& chapter_index) {
    std::string digits;
    for (char c : chapter_index) {
        if (!std::isdigit((unsigned char)c)) break;
        digits.push_back(c);
    }
    size_t value = digits.empty() ? 1 : (size_t)std::strtoull(digits.c_str(), nullptr, 10);
    if (value == 0) value = 1;
    return ((value - 1) / kChaptersPerShard) + 1;
}

std::string shard_path(const std::string& root_dir, const std::string& domain,
                       const std::string& novel_id, const std::string& chapter_index) {
    char buf[16];
    std::snprintf(buf, sizeof buf, "%04zu.db", shard_number(chapter_index));
    return novel_shard_dir(root_dir, domain, novel_id) + "/" + buf;
}

std::string domain_from_novel_id(const std::string& novel_id) {
    size_t at = novel_id.find(':');
    return at == std::string::npos ? "unknown" : novel_id.substr(0, at);
}

} // namespace

std::string novel_shard_dir(const std::string& root_dir, const std::string& domain,
                            const std::string& novel_id) {
    return root_dir + "/" + kNovelsDirName + "/" + safe_path_component(domain) + "/" +
           safe_path_component(novel_id);
}

#if defined(NC_HAVE_ZSTD)
std::string compress_zstd_str(const std::string& s) {
    size_t bound = ZSTD_compressBound(s.size());
    std::string out(bound, '\0');
    size_t n = ZSTD_compress(out.data(), bound, s.data(), s.size(), kFastZstdLevel);
    if (ZSTD_isError(n)) throw Error(std::string("zstd compress: ") + ZSTD_getErrorName(n));
    out.resize(n);
    return out;
}

std::string decompress_zstd_str(const std::string& blob) {
    unsigned long long raw = ZSTD_getFrameContentSize(blob.data(), blob.size());
    if (raw == ZSTD_CONTENTSIZE_ERROR) throw Error("zstd: not a zstd frame");
    size_t cap = (raw == ZSTD_CONTENTSIZE_UNKNOWN) ? blob.size() * 64 + 4096 : (size_t)raw;
    std::string out(cap, '\0');
    size_t n = ZSTD_decompress(out.data(), cap, blob.data(), blob.size());
    if (ZSTD_isError(n)) throw Error(std::string("zstd decompress: ") + ZSTD_getErrorName(n));
    out.resize(n);
    return out;
}

std::string decompress_zstd_dict(const std::string& blob, const std::string& dictionary) {
    if (dictionary.empty()) return decompress_zstd_str(blob);
    ZSTD_DCtx* dctx = ZSTD_createDCtx();
    if (!dctx) throw Error("zstd: createDCtx failed");
    unsigned long long raw = ZSTD_getFrameContentSize(blob.data(), blob.size());
    size_t cap = (raw == ZSTD_CONTENTSIZE_UNKNOWN || raw == ZSTD_CONTENTSIZE_ERROR)
                     ? blob.size() * 64 + 4096
                     : (size_t)raw;
    std::string out(cap, '\0');
    size_t rc = ZSTD_decompress_usingDict(dctx, out.data(), cap, blob.data(), blob.size(),
                                          dictionary.data(), dictionary.size());
    ZSTD_freeDCtx(dctx);
    if (ZSTD_isError(rc)) throw Error(std::string("zstd dict decompress: ") + ZSTD_getErrorName(rc));
    out.resize(rc);
    return out;
}
#else
// NC_HAVE_ZSTD 未定義ビルド (Nyxian 等): 生バイトで保存する。
std::string compress_zstd_str(const std::string& s) { return s; }
std::string decompress_zstd_str(const std::string& blob) { return blob; }
std::string decompress_zstd_dict(const std::string& blob, const std::string& /*dictionary*/) {
    return blob;
}
#endif

std::string library_database_path(const std::string& output_dir) {
    fs::path p(output_dir);
    fs::path parent = p.parent_path();
    return (parent.empty() ? p : parent).string() + "/" + kMasterDbName;
}

std::string novel_id_from_toc_url(const std::string& toc_url) {
    UrlParts parts;
    if (url_parse(toc_url, parts)) {
        std::string host = parts.host;
        if (starts_with(host, "www.")) host = host.substr(4);
        std::string path = parts.path;
        while (!path.empty() && path.back() == '/') path.pop_back();
        return host + ":" + path;
    }
    return lower(toc_url);
}

double section_sort_key(const std::string& chapter_index) {
    try {
        return std::stod(chapter_index);
    } catch (...) {
        // stable pseudo-order for non-numeric indices
        unsigned long long h = 1469598103934665603ULL;
        for (unsigned char c : chapter_index) {
            h ^= c;
            h *= 1099511628211ULL;
        }
        return (double)(h % 1000000ULL) / 1000.0;
    }
}

// ── SectionStorage ────────────────────────────────────────────────────────
struct SectionStorage::Impl {
    Sqlite master;
    std::string root;
    std::string master_path;
    std::mutex pool_mutex;
    std::map<std::string, Sqlite> pool;
    std::vector<std::string> lru;

    Sqlite& shard(const std::string& path) {
        std::lock_guard<std::mutex> lock(pool_mutex);
        auto it = pool.find(path);
        if (it == pool.end()) {
            std::error_code ec;
            fs::create_directories(fs::path(path).parent_path(), ec);
            if (pool.size() >= 8) {
                // evict LRU tail
                while (pool.size() >= 8 && !lru.empty()) {
                    std::string victim = lru.back();
                    lru.pop_back();
                    if (victim != path) pool.erase(victim);
                }
            }
            Sqlite db(path);
            configure_connection(db, false);
            migrate_shard(db);
            it = pool.emplace(path, std::move(db)).first;
        }
        // touch LRU
        lru.erase(std::remove(lru.begin(), lru.end(), path), lru.end());
        lru.insert(lru.begin(), path);
        return it->second;
    }

    std::string domain_for_novel(const std::string& novel_id) {
        Stmt stmt(master.prepare("SELECT domain FROM novels WHERE novel_id = ?1"));
        stmt.bind_text(1, novel_id);
        if (stmt.step()) {
            std::string d = stmt.col_text(0);
            if (!d.empty()) return d;
        }
        return domain_from_novel_id(novel_id);
    }

    std::string shard_path_for_chapter(const std::string& novel_id,
                                      const std::string& chapter_index) {
        return shard_path(root, domain_for_novel(novel_id), novel_id, chapter_index);
    }
};

SectionStorage::SectionStorage(const std::string& master_path)
    : impl_(new Impl()) {
    std::error_code ec;
    fs::create_directories(fs::path(master_path).parent_path(), ec);
    impl_->master = Sqlite(master_path);
    configure_connection(impl_->master, true);
    migrate_master(impl_->master);
    impl_->master_path = master_path;
    fs::path parent = fs::path(master_path).parent_path();
    impl_->root = parent.empty() ? "." : parent.string();
}

SectionStorage::~SectionStorage() = default;
SectionStorage::SectionStorage(SectionStorage&&) noexcept = default;
SectionStorage& SectionStorage::operator=(SectionStorage&&) noexcept = default;

std::string SectionStorage::root_dir() const { return impl_->root; }

void SectionStorage::update_novel_description(const std::string& novel_id,
                                              const std::string& description) {
    if (description.empty()) return;
    Stmt stmt(impl_->master.prepare(
        "UPDATE novels SET description = ?1 WHERE novel_id = ?2"));
    stmt.bind_text(1, description);
    stmt.bind_text(2, novel_id);
    while (stmt.step()) {
    }
}

std::string SectionStorage::novel_description(const std::string& novel_id) {
    Stmt stmt(impl_->master.prepare(
        "SELECT description FROM novels WHERE novel_id = ?1"));
    stmt.bind_text(1, novel_id);
    if (!stmt.step()) return "";
    return stmt.col_text(0);
}

void SectionStorage::upsert_novel(const std::string& novel_id, const std::string& title,
                                  const std::string& author, const std::string& toc_url,
                                  const std::string& domain, const std::string& output_dir,
                                  long long episode_count, const std::string& updated_at) {
    std::string shard_dir = novel_shard_dir(impl_->root, domain, novel_id);
    Stmt stmt(impl_->master.prepare(R"SQL(
        INSERT INTO novels
            (novel_id, title, author, toc_url, domain, output_dir, shard_dir, episode_count,
             created_at, updated_at, last_downloaded_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?9)
        ON CONFLICT(novel_id) DO UPDATE SET
            title  = CASE WHEN excluded.title != '' THEN excluded.title ELSE novels.title END,
            author = CASE WHEN excluded.author != '' THEN excluded.author ELSE novels.author END,
            toc_url = excluded.toc_url,
            domain = excluded.domain,
            output_dir = excluded.output_dir,
            shard_dir = excluded.shard_dir,
            episode_count = excluded.episode_count,
            updated_at = excluded.updated_at,
            last_downloaded_at = excluded.last_downloaded_at
    )SQL"));
    stmt.bind_text(1, novel_id);
    stmt.bind_text(2, title);
    stmt.bind_text(3, author);
    stmt.bind_text(4, toc_url);
    stmt.bind_text(5, domain);
    stmt.bind_text(6, output_dir);
    stmt.bind_text(7, shard_dir);
    stmt.bind_int64(8, episode_count);
    stmt.bind_text(9, updated_at);
    stmt.step();
}

void SectionStorage::upsert_sections(const std::vector<SectionUpsert>& sections) {
    std::map<std::string, std::vector<const SectionUpsert*>> grouped;
    for (auto& s : sections)
        grouped[impl_->shard_path_for_chapter(s.novel_id, s.chapter_index)].push_back(&s);
    for (auto& kv : grouped) {
        Sqlite& db = impl_->shard(kv.first);
        db.exec("BEGIN");
        try {
            Stmt upsert(db.prepare(R"SQL(
                INSERT INTO sections
                    (novel_id, chapter_index, sort_key, subtitle, source_url,
                     intro_xhtml_zstd, body_xhtml_zstd, post_xhtml_zstd,
                     intro_zstd_dict_id, body_zstd_dict_id, post_zstd_dict_id,
                     source_signature, body_downloaded, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, NULL, ?9, 1, ?10)
                ON CONFLICT(novel_id, chapter_index) DO UPDATE SET
                    sort_key = excluded.sort_key,
                    subtitle = excluded.subtitle,
                    source_url = excluded.source_url,
                    intro_xhtml_zstd = excluded.intro_xhtml_zstd,
                    body_xhtml_zstd = excluded.body_xhtml_zstd,
                    post_xhtml_zstd = excluded.post_xhtml_zstd,
                    source_signature = excluded.source_signature,
                    body_downloaded = 1,
                    updated_at = excluded.updated_at
            )SQL"));
            Stmt del_fts(db.prepare(
                "DELETE FROM sections_fts WHERE novel_id = ?1 AND chapter_index = ?2"));
            Stmt ins_fts(db.prepare(
                "INSERT INTO sections_fts(novel_id, chapter_index, subtitle, body_text) "
                "VALUES(?1, ?2, ?3, ?4)"));
            for (auto* s : kv.second) {
                upsert.bind_text(1, s->novel_id);
                upsert.bind_text(2, s->chapter_index);
                upsert.bind_double(3, section_sort_key(s->chapter_index));
                upsert.bind_text(4, s->subtitle);
                upsert.bind_text(5, s->source_url);
                if (s->intro_xhtml)
                    upsert.bind_blob(6, compress_zstd_str(*s->intro_xhtml));
                else
                    upsert.bind_null(6);
                upsert.bind_blob(7, compress_zstd_str(s->body_xhtml));
                if (s->post_xhtml)
                    upsert.bind_blob(8, compress_zstd_str(*s->post_xhtml));
                else
                    upsert.bind_null(8);
                upsert.bind_text(9, s->source_signature);
                upsert.bind_text(10, s->updated_at);
                upsert.step();
                upsert.reset();

                std::string searchable = (s->intro_xhtml.value_or("") + "\n" + s->body_xhtml +
                                         "\n" + s->post_xhtml.value_or(""));
                del_fts.bind_text(1, s->novel_id);
                del_fts.bind_text(2, s->chapter_index);
                del_fts.step();
                del_fts.reset();
                ins_fts.bind_text(1, s->novel_id);
                ins_fts.bind_text(2, s->chapter_index);
                ins_fts.bind_text(3, s->subtitle);
                ins_fts.bind_text(4, searchable);
                ins_fts.step();
                ins_fts.reset();
            }
            db.exec("COMMIT");
        } catch (...) {
            try {
                db.exec("ROLLBACK");
            } catch (...) {
            }
            throw;
        }
    }
}

void SectionStorage::upsert_section_placeholders(const std::string& novel_id,
                                                 const std::vector<StoredTocChapter>& chapters,
                                                 const std::string& updated_at) {
    std::map<std::string, std::vector<const StoredTocChapter*>> grouped;
    for (auto& c : chapters)
        grouped[impl_->shard_path_for_chapter(novel_id, c.index)].push_back(&c);
    std::string empty_body = compress_zstd_str("");
    for (auto& kv : grouped) {
        Sqlite& db = impl_->shard(kv.first);
        db.exec("BEGIN");
        try {
            Stmt upsert(db.prepare(R"SQL(
                INSERT INTO sections
                    (novel_id, chapter_index, sort_key, subtitle, source_url,
                     intro_xhtml_zstd, body_xhtml_zstd, post_xhtml_zstd,
                     intro_zstd_dict_id, body_zstd_dict_id, post_zstd_dict_id,
                     source_signature, body_downloaded, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, NULL, NULL, NULL, '', 0, ?7)
                ON CONFLICT(novel_id, chapter_index) DO UPDATE SET
                    sort_key = excluded.sort_key,
                    subtitle = excluded.subtitle,
                    source_url = CASE WHEN excluded.source_url != ''
                                      THEN excluded.source_url ELSE sections.source_url END,
                    body_downloaded = sections.body_downloaded,
                    updated_at = CASE WHEN sections.source_signature = ''
                                      THEN excluded.updated_at ELSE sections.updated_at END
            )SQL"));
            Stmt del_fts(db.prepare(
                "DELETE FROM sections_fts WHERE novel_id = ?1 AND chapter_index = ?2"));
            for (auto* c : kv.second) {
                upsert.bind_text(1, novel_id);
                upsert.bind_text(2, c->index);
                upsert.bind_double(3, section_sort_key(c->index));
                upsert.bind_text(4, c->subtitle);
                upsert.bind_text(5, c->href);
                upsert.bind_blob(6, empty_body);
                upsert.bind_text(7, updated_at);
                upsert.step();
                upsert.reset();
                del_fts.bind_text(1, novel_id);
                del_fts.bind_text(2, c->index);
                del_fts.step();
                del_fts.reset();
            }
            db.exec("COMMIT");
        } catch (...) {
            try {
                db.exec("ROLLBACK");
            } catch (...) {
            }
            throw;
        }
    }
}

std::optional<std::pair<std::string, std::string>>
SectionStorage::novel_metadata(const std::string& novel_id) {
    Stmt stmt(impl_->master.prepare("SELECT title, author FROM novels WHERE novel_id = ?1"));
    stmt.bind_text(1, novel_id);
    if (!stmt.step()) return std::nullopt;
    return std::make_pair(stmt.col_text(0), stmt.col_text(1));
}

std::string SectionStorage::novel_domain(const std::string& novel_id) {
    return impl_->domain_for_novel(novel_id);
}

std::string SectionStorage::novel_output_dir(const std::string& novel_id) {
    Stmt stmt(impl_->master.prepare("SELECT output_dir FROM novels WHERE novel_id = ?1"));
    stmt.bind_text(1, novel_id);
    if (stmt.step()) {
        std::string dir = stmt.col_text(0);
        if (!dir.empty()) return dir;
    }
    return impl_->root;
}

std::vector<StoredTocChapter>
SectionStorage::cached_toc_chapters(const std::string& novel_id) {
    std::vector<StoredTocChapter> out;
    std::error_code ec;
    std::string dir = novel_shard_dir(impl_->root, impl_->domain_for_novel(novel_id), novel_id);
    std::vector<std::string> paths;
    if (fs::exists(dir, ec)) {
        for (auto& entry : fs::directory_iterator(dir, ec))
            if (entry.path().extension() == ".db") paths.push_back(entry.path().string());
        std::sort(paths.begin(), paths.end());
    }
    for (auto& path : paths) {
        if (!fs::exists(path, ec)) continue;
        Sqlite& db = impl_->shard(path);
        Stmt stmt(db.prepare(R"SQL(
            SELECT chapter_index, source_url, subtitle FROM sections
            WHERE novel_id = ?1 AND source_url != ''
            ORDER BY sort_key, chapter_index
        )SQL"));
        stmt.bind_text(1, novel_id);
        while (stmt.step())
            out.push_back({stmt.col_text(0), stmt.col_text(1), stmt.col_text(2)});
    }
    return out;
}

std::optional<std::pair<std::string, bool>> SectionStorage::section_download_state(
    const std::string& novel_id, const std::string& chapter_index) {
    std::string path = impl_->shard_path_for_chapter(novel_id, chapter_index);
    std::error_code ec;
    if (!fs::exists(path, ec)) return std::nullopt;
    Sqlite& db = impl_->shard(path);
    Stmt stmt(db.prepare(
        "SELECT source_signature, body_downloaded FROM sections "
        "WHERE novel_id = ?1 AND chapter_index = ?2"));
    stmt.bind_text(1, novel_id);
    stmt.bind_text(2, chapter_index);
    if (!stmt.step()) return std::nullopt;
    return std::make_pair(stmt.col_text(0), stmt.col_int64(1) != 0);
}

std::map<std::string, std::pair<std::string, bool>>
SectionStorage::section_download_states(const std::string& novel_id) {
    std::map<std::string, std::pair<std::string, bool>> out;
    std::error_code ec;
    std::string dir = novel_shard_dir(impl_->root, impl_->domain_for_novel(novel_id), novel_id);
    if (!fs::exists(dir, ec)) return out;
    std::vector<std::string> paths;
    for (auto& entry : fs::directory_iterator(dir, ec))
        if (entry.path().extension() == ".db") paths.push_back(entry.path().string());
    std::sort(paths.begin(), paths.end());
    for (auto& path : paths) {
        Sqlite& db = impl_->shard(path);
        Stmt stmt(db.prepare(
            "SELECT chapter_index, source_signature, body_downloaded FROM sections "
            "WHERE novel_id = ?1"));
        stmt.bind_text(1, novel_id);
        while (stmt.step())
            out[stmt.col_text(0)] = std::make_pair(stmt.col_text(1), stmt.col_int64(2) != 0);
    }
    return out;
}

std::optional<StoredSection> SectionStorage::get_section(const std::string& novel_id,
                                                         const std::string& chapter_index) {
    std::string path = impl_->shard_path_for_chapter(novel_id, chapter_index);
    std::error_code ec;
    if (!fs::exists(path, ec)) return std::nullopt;
    Sqlite& db = impl_->shard(path);
    Stmt stmt(db.prepare(R"SQL(
        SELECT chapter_index, subtitle, source_url,
               intro_xhtml_zstd, body_xhtml_zstd, post_xhtml_zstd,
               intro_zstd_dict_id, body_zstd_dict_id, post_zstd_dict_id,
               source_signature, body_downloaded, updated_at, sort_key
        FROM sections WHERE novel_id = ?1 AND chapter_index = ?2
    )SQL"));
    stmt.bind_text(1, novel_id);
    stmt.bind_text(2, chapter_index);
    if (!stmt.step()) return std::nullopt;
    auto decode = [&](int blob_col, int dict_col) -> std::string {
        if (stmt.col_null(blob_col)) return "";
        std::string blob = stmt.col_blob(blob_col);
        std::string dict;
        if (!stmt.col_null(dict_col)) {
            std::string dict_id = stmt.col_text(dict_col);
            Stmt dstmt(db.prepare(
                "SELECT dictionary FROM zstd_dictionaries WHERE novel_id = ?1 AND dict_id = ?2"));
            dstmt.bind_text(1, novel_id);
            dstmt.bind_text(2, dict_id);
            if (dstmt.step()) dict = dstmt.col_blob(0);
        }
        return dict.empty() ? decompress_zstd_str(blob) : decompress_zstd_dict(blob, dict);
    };
    StoredSection sec;
    sec.index = stmt.col_text(0);
    sec.subtitle = stmt.col_text(1);
    sec.source_url = stmt.col_text(2);
    sec.intro_xhtml = decode(3, 6);
    sec.body_xhtml = decode(4, 7);
    sec.post_xhtml = decode(5, 8);
    sec.source_signature = stmt.col_text(9);
    sec.body_downloaded = stmt.col_int64(10) != 0;
    sec.updated_at = stmt.col_text(11);
    sec.sort_key = stmt.col_double(12);
    return sec;
}

std::vector<NovelListItem> SectionStorage::list_novels() {
    return list_novels_in_existing_db(impl_->master_path, impl_->root);
}

std::vector<NovelListItem> SectionStorage::list_novels_in_existing_db(
    const std::string& db_path, const std::string& fallback_output_dir) {
    std::vector<NovelListItem> out;
    std::error_code ec;
    if (!fs::exists(db_path, ec)) return out;
    Sqlite db(db_path);
    // read-only listing; tolerate legacy schemas
    std::string sql = R"(
        SELECT novel_id, title, author, toc_url, domain, episode_count, updated_at,
               CASE WHEN EXISTS (SELECT 1 FROM pragma_table_info('novels') WHERE name='output_dir')
                    THEN output_dir ELSE '' END,
               CASE WHEN EXISTS (SELECT 1 FROM pragma_table_info('novels') WHERE name='shard_dir')
                    THEN shard_dir ELSE '' END
        FROM novels
        ORDER BY updated_at DESC, title ASC, novel_id ASC)";
    try {
        Stmt stmt(db.prepare(sql));
        while (stmt.step()) {
            NovelListItem item;
            item.novel_id = stmt.col_text(0);
            item.title = stmt.col_text(1);
            item.author = stmt.col_text(2);
            item.toc_url = stmt.col_text(3);
            item.domain = stmt.col_text(4);
            item.episode_count = stmt.col_int64(5);
            item.updated_at = stmt.col_text(6);
            item.output_dir = stmt.col_text(7);
            if (item.output_dir.empty()) item.output_dir = fallback_output_dir;
            item.storage_path = db_path;
            out.push_back(std::move(item));
        }
    } catch (const std::exception& e) {
        throw Error(std::string("list novels: ") + e.what());
    }
    return out;
}

std::vector<NovelListItem> discover_downloaded_novels(const std::string& root_dir) {
    std::vector<NovelListItem> items;
    std::error_code ec;
    std::string master = root_dir + "/" + kMasterDbName;
    std::string legacy = root_dir + "/" + kLegacyDbName;
    if (fs::exists(master, ec))
        for (auto& n : SectionStorage::list_novels_in_existing_db(master, root_dir))
            items.push_back(n);
    if (fs::exists(legacy, ec))
        for (auto& n : SectionStorage::list_novels_in_existing_db(legacy, root_dir))
            items.push_back(n);
    if (fs::is_directory(root_dir, ec)) {
        for (auto& entry : fs::directory_iterator(root_dir, ec)) {
            if (!entry.is_directory()) continue;
            for (const char* name : {kMasterDbName, kLegacyDbName}) {
                std::string path = entry.path().string() + "/" + name;
                if (fs::exists(path, ec)) {
                    try {
                        for (auto& n :
                             SectionStorage::list_novels_in_existing_db(path, entry.path().string()))
                            items.push_back(n);
                    } catch (...) {
                    }
                }
            }
        }
    }
    // dedupe by toc_url (fallback novel_id), master first then updated_at
    std::sort(items.begin(), items.end(), [&](const NovelListItem& a, const NovelListItem& b) {
        bool a_master = ends_with(a.storage_path, kMasterDbName);
        bool b_master = ends_with(b.storage_path, kMasterDbName);
        if (a_master != b_master) return a_master;
        if (a.updated_at != b.updated_at) return a.updated_at > b.updated_at;
        return a.title < b.title;
    });
    std::map<std::string, bool> seen;
    std::vector<NovelListItem> unique;
    for (auto& item : items) {
        std::string key = item.toc_url.empty() ? item.novel_id : item.toc_url;
        if (seen[key]) continue;
        seen[key] = true;
        unique.push_back(item);
    }
    std::sort(unique.begin(), unique.end(), [](const NovelListItem& a, const NovelListItem& b) {
        if (a.updated_at != b.updated_at) return a.updated_at > b.updated_at;
        if (a.title != b.title) return a.title < b.title;
        return a.novel_id < b.novel_id;
    });
    return unique;
}

} // namespace nc
