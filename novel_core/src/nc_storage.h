// nc_storage.h — library storage: master.db metadata + sharded section DBs.
#pragma once

#include "nc_common.h"

#include <optional>

namespace nc {

struct NovelListItem {
    std::string novel_id;
    std::string title;
    std::string author;
    std::string toc_url;
    std::string domain;
    long long episode_count = 0;
    long long downloaded_count = 0;
    std::string updated_at;
    std::string output_dir;
    std::string storage_path;
};

struct StoredTocChapter {
    std::string index;
    std::string href;
    std::string subtitle;
};

struct StoredSection {
    std::string index;
    std::string subtitle;
    std::string source_url;
    std::string intro_xhtml; // empty when absent
    std::string body_xhtml;
    std::string post_xhtml;
    std::string source_signature;
    std::string updated_at;
    bool body_downloaded = false;
    double sort_key = 0;
};

struct SectionUpsert {
    std::string novel_id;
    std::string chapter_index;
    std::string subtitle;
    std::string source_url;
    std::optional<std::string> intro_xhtml;
    std::string body_xhtml;
    std::optional<std::string> post_xhtml;
    std::string source_signature;
    std::string updated_at;
};

std::string library_database_path(const std::string& output_dir);
std::string novel_shard_dir(const std::string& root_dir, const std::string& domain,
                            const std::string& novel_id);
std::string novel_id_from_toc_url(const std::string& toc_url);
double section_sort_key(const std::string& chapter_index);
std::string compress_zstd_str(const std::string& s);
std::string decompress_zstd_str(const std::string& blob);
std::string decompress_zstd_dict(const std::string& blob, const std::string& dictionary);

class SectionStorage {
public:
    // opens/creates master db at `master_path`
    explicit SectionStorage(const std::string& master_path);
    ~SectionStorage();
    SectionStorage(SectionStorage&&) noexcept;
    SectionStorage& operator=(SectionStorage&&) noexcept;
    SectionStorage(const SectionStorage&) = delete;

    std::string root_dir() const;

    void upsert_novel(const std::string& novel_id, const std::string& title,
                      const std::string& author, const std::string& toc_url,
                      const std::string& domain, const std::string& output_dir,
                      long long episode_count, const std::string& updated_at);
    void upsert_sections(const std::vector<SectionUpsert>& sections);
    void upsert_section_placeholders(const std::string& novel_id,
                                     const std::vector<StoredTocChapter>& chapters,
                                     const std::string& updated_at);

    std::optional<std::pair<std::string, std::string>>
    novel_metadata(const std::string& novel_id); // title, author
    std::string novel_domain(const std::string& novel_id);
    std::string novel_output_dir(const std::string& novel_id);
    std::vector<StoredTocChapter> cached_toc_chapters(const std::string& novel_id);

    // chapter_index -> (source_signature, body_downloaded)
    std::optional<std::pair<std::string, bool>> section_download_state(
        const std::string& novel_id, const std::string& chapter_index);
    std::map<std::string, std::pair<std::string, bool>> section_download_states(
        const std::string& novel_id);
    std::optional<StoredSection> get_section(const std::string& novel_id,
                                             const std::string& chapter_index);

    std::vector<NovelListItem> list_novels();

    static std::vector<NovelListItem> list_novels_in_existing_db(
        const std::string& db_path, const std::string& fallback_output_dir);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

std::vector<NovelListItem> discover_downloaded_novels(const std::string& root_dir);

} // namespace nc
