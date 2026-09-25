// nc_value.h — dynamic value node shared by YAML and JSON (serde Value port).
#pragma once

#include "nc_common.h"

namespace nc {

struct Value {
    enum class T { Null, Bool, Int, Real, Str, Array, Map };
    T t = T::Null;
    bool b = false;
    long long i = 0;
    double d = 0;
    std::string s;
    std::vector<Value> arr;
    std::vector<std::pair<std::string, Value>> map; // insertion ordered

    Value() = default;
    static Value null() { return {}; }
    static Value boolean(bool v) { Value x; x.t = T::Bool; x.b = v; return x; }
    static Value integer(long long v) { Value x; x.t = T::Int; x.i = v; return x; }
    static Value real(double v) { Value x; x.t = T::Real; x.d = v; return x; }
    static Value string(std::string v) { Value x; x.t = T::Str; x.s = std::move(v); return x; }
    static Value array() { Value x; x.t = T::Array; return x; }
    static Value map_() { Value x; x.t = T::Map; return x; }

    bool is_null() const { return t == T::Null; }
    bool is_map() const { return t == T::Map; }
    bool is_array() const { return t == T::Array; }
    bool is_str() const { return t == T::Str; }
    bool is_bool() const { return t == T::Bool; }
    bool is_num() const { return t == T::Int || t == T::Real; }

    const std::string* as_str_opt() const { return t == T::Str ? &s : nullptr; }
    std::string as_str() const {
        switch (t) {
        case T::Str: return s;
        case T::Int: return std::to_string(i);
        case T::Real: return to_str(d);
        case T::Bool: return b ? "true" : "false";
        case T::Null: return "";
        default: return "";
        }
    }
    std::optional<std::string> as_str_nonempty() const {
        if (t != T::Str) return std::nullopt;
        std::string v = trim(s);
        return v.empty() ? std::nullopt : std::optional<std::string>(v);
    }
    bool as_bool_or(bool fallback) const {
        if (t == T::Bool) return b;
        if (t == T::Str) {
            std::string v = lower(trim(s));
            if (v == "true" || v == "yes" || v == "on" || v == "1") return true;
            if (v == "false" || v == "no" || v == "off" || v == "0") return false;
        }
        return fallback;
    }
    long long as_int_or(long long fallback) const {
        if (t == T::Int) return i;
        if (t == T::Real) return (long long)d;
        if (t == T::Str) {
            try { return std::stoll(trim(s)); } catch (...) {}
        }
        return fallback;
    }
    size_t as_size_or(size_t fallback) const {
        long long v = as_int_or(-1);
        return v < 0 ? fallback : (size_t)v;
    }

    // map access
    const Value* get(const std::string& key) const {
        if (t != T::Map) return nullptr;
        for (auto& kv : map) if (kv.first == key) return &kv.second;
        return nullptr;
    }
    Value* get_mut(const std::string& key) {
        if (t != T::Map) return nullptr;
        for (auto& kv : map) if (kv.first == key) return &kv.second;
        return nullptr;
    }
    void set(const std::string& key, Value v) {
        t = T::Map;
        for (auto& kv : map) {
            if (kv.first == key) { kv.second = std::move(v); return; }
        }
        map.emplace_back(key, std::move(v));
    }
    bool contains(const std::string& key) const { return get(key) != nullptr; }
    std::string get_str(const std::string& key, const std::string& fallback = "") const {
        const Value* v = get(key);
        return v ? v->as_str() : fallback;
    }
    std::optional<std::string> get_str_opt(const std::string& key) const {
        const Value* v = get(key);
        return v ? v->as_str_nonempty() : std::nullopt;
    }
    long long get_int(const std::string& key, long long fallback = 0) const {
        const Value* v = get(key);
        return v ? v->as_int_or(fallback) : fallback;
    }
    bool get_bool(const std::string& key, bool fallback = false) const {
        const Value* v = get(key);
        return v ? v->as_bool_or(fallback) : fallback;
    }
    // array access
    void push(Value v) { t = T::Array; arr.push_back(std::move(v)); }
    size_t size() const { return t == T::Array ? arr.size() : (t == T::Map ? map.size() : 0); }
};

// ── JSON ──────────────────────────────────────────────────────────────────
Value json_parse(const std::string& text);
std::string json_dump(const Value& v, bool pretty = false);

// JSONPath subset: "$.a.b[0].c" / "a.b" / "$"
const Value* json_path(const Value& root, const std::string& path);
std::optional<std::string> json_path_string(const Value& root, const std::string& path);
std::optional<std::string> json_value_to_string(const Value& v);

// deep merge (config_manager::merge_yaml semantics: overlay wins)
void value_merge(Value& base, const Value& overlay);

// ── YAML ──────────────────────────────────────────────────────────────────
Value yaml_parse(const std::string& text);
std::string yaml_dump(const Value& v);

} // namespace nc
