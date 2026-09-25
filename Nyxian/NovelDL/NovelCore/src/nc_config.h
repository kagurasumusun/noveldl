// nc_config.h — root dir / preset store / global config.
#pragma once

#include "nc_common.h"
#include "nc_value.h"

namespace nc {

namespace config {

// directories
std::string root_dir();
void set_root_dir(const std::string& path);
std::string script_dir();
void set_script_dir(const std::string& path);
std::string tmp_dir();
std::string user_presets_dir();

// YAML presets: builtins seeded into <root>/presets/... and user overlays.
// resolve `extends: common/foo` recursively and deep-merge.
Value resolve_extends(Value preset);
// effective preset for a domain = builtin + user parser + user webnovel overlay
Value load_effective_preset(const std::string& domain);
std::optional<Value> load_builtin_preset(const std::string& kind, const std::string& domain);
void seed_default_presets();
Value save_user_preset(const std::string& kind, const std::string& domain, const Value& yaml);
bool delete_user_preset(const std::string& kind, const std::string& domain);
Value list_presets();

// global parser_config.yaml (domain -> engine hints; persisted settings)
Value load_global_config();
void save_global_config(const Value& v);

} // namespace config

// builtin preset registry (nc_builtin_presets.cpp, generated from presets/)
struct BuiltinPreset {
    const char* kind;    // "parsers" | "parsers/common"
    const char* domain;
    const char* yaml;
};
const std::vector<BuiltinPreset>& builtin_presets();

} // namespace nc
