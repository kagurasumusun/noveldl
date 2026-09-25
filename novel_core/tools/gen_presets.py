#!/usr/bin/env python3
"""Generate src/nc_builtin_presets.cpp from presets/parsers/*.yaml."""
import pathlib

BASE = pathlib.Path(__file__).resolve().parent.parent
ROOT = BASE / "presets" / "parsers"

entries = []
for p in sorted(ROOT.rglob("*.yaml")):
    rel = p.relative_to(ROOT)
    if rel.parent.name == "common":
        kind = "parsers/common"
        domain = rel.stem
    else:
        kind = "parsers"
        domain = rel.name[:-5]
    entries.append((kind, domain, p.read_text(encoding="utf-8")))

out = []
out.append("// nc_builtin_presets.cpp — GENERATED from presets/parsers/*.yaml")
out.append("// Site support is data driven: edit the YAML files (or user overlays),")
out.append("// never C/C++, to add or fix sites.  Regenerate with tools/gen_presets.py.")
out.append('#include "nc_config.h"')
out.append("")
out.append("namespace nc {")
out.append("")
out.append("const std::vector<BuiltinPreset>& builtin_presets() {")
out.append("    static const std::vector<BuiltinPreset> presets = {")
for kind, domain, text in entries:
    delim = "NC"
    while (")" + delim + '"') in text:
        delim += "X"
    out.append('        {"%s", "%s", R"%s(' % (kind, domain, delim))
    out.append(text.rstrip("\n"))
    out.append(')%s"},' % delim)
out.append("    };")
out.append("    return presets;")
out.append("}")
out.append("")
out.append("} // namespace nc")

dest = BASE / "src" / "nc_builtin_presets.cpp"
dest.write_text("\n".join(out) + "\n", encoding="utf-8")
print("generated", len(entries), "presets ->", dest)
