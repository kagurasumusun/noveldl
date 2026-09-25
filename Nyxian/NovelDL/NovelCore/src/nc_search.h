// nc_search.h
#pragma once
#include "nc_value.h"
namespace nc {
Value search_novels(const std::string& query, int limit);
Value search_supported_sites();
} // namespace nc
