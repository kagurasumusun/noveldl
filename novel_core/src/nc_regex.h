// nc_regex.h — regular expression engine (std::regex wrapper with named groups,
// dotall / case-insensitive translation and Rust-regex compatible `$` semantics).
#pragma once

#include "nc_common.h"

#include <functional>

namespace nc {

class Regex {
public:
    struct Match {
        std::vector<std::string> groups; // 0 = whole match
        std::vector<bool> present;
        std::vector<std::string> names;  // names[i] -> group index i+1
        size_t position = 0;
        size_t length = 0;

        bool has(size_t idx) const {
            return idx < present.size() && present[idx];
        }
        std::optional<std::string> get(size_t idx) const {
            return has(idx) ? std::optional<std::string>(groups[idx]) : std::nullopt;
        }
        std::string get_or(size_t idx, const std::string& fallback) const {
            auto v = get(idx);
            return v ? *v : fallback;
        }
        std::optional<std::string> name(const std::string& name) const {
            for (size_t k = 0; k < names.size(); ++k)
                if (names[k] == name) return get(k + 1);
            return std::nullopt;
        }
        std::string name_or(const std::string& name, const std::string& fallback) const {
            auto v = this->name(name);
            return v ? *v : fallback;
        }
    };

    Regex(const std::string& pattern, bool dotall = false, bool icase = false);

    std::optional<Match> search(const std::string& text) const;
    std::optional<Match> search_at(const std::string& text, size_t pos) const;
    std::vector<Match> find_all(const std::string& text) const;
    bool is_match(const std::string& text) const;
    std::string replace_all(const std::string& text, const std::string& repl) const; // $1..$9 ${name}
    std::string replace_all(const std::string& text,
                            const std::function<std::string(const Match&)>& fn) const;
    // split with limit (limit=0: all).  Returns pieces (captures not included).
    std::vector<std::string> split(const std::string& text, size_t limit = 0) const;
    const std::vector<std::string>& names() const { return names_; }
    const std::string& pattern() const { return pattern_; }

private:
    std::string pattern_;
    std::shared_ptr<void> re_; // std::regex
    std::vector<std::string> names_;
    friend struct RegexImpl;
};

} // namespace nc
