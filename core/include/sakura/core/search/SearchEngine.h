// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_CORE_SEARCH_SEARCH_ENGINE_H_
#define SAKURA_CORE_SEARCH_SEARCH_ENGINE_H_

#include <cstddef>
#include <functional>
#include <optional>
#include <vector>

#include "sakura/core/text/TextBuffer.h"

namespace sakura::core {

struct SearchOptions {
  bool caseSensitive{true};
  bool wholeWord{};
  bool wrap{true};
  bool regularExpression{};
  // Optional cancellation is checked during scanning and ICU backtracking.
  std::function<bool()> cancelled;
  // findAll only: zero means unlimited. replaceAll always processes all hits.
  std::size_t maxMatches{};
  std::int32_t regexTimeLimitMilliseconds{1000};
  // replaceAll only: cap both aggregate replacement text and final document.
  std::size_t maxReplacementCodeUnits{};
};

struct SearchMatch {
  TextRange range;
  // Absolute UTF-16 capture ranges from the original document. Entry zero is
  // the entire match; unmatched optional groups have no range.
  std::vector<std::optional<TextRange>> captures;
  friend constexpr bool operator==(const SearchMatch&, const SearchMatch&) = default;
};

// UTF-16 search over the document model. Literal case-insensitive matching
// deliberately folds ASCII only. Regular expressions use ICU Unicode syntax;
// invalid expressions yield no matches. This is not Bregonig/Onigmo syntax.
class SearchEngine {
 public:
  [[nodiscard]] static bool isValidPattern(
      SakuraStringView needle, SearchOptions options = {});
  // Expand captures retained by findNext/findAll, preserving lookaround and
  // anchor context instead of matching an isolated substring again.
  [[nodiscard]] static SakuraString expandReplacement(
      SakuraStringView source, const SearchMatch& match,
      SakuraStringView replacement,
      std::optional<std::size_t> outputLimit = std::nullopt);
  [[nodiscard]] std::optional<SearchMatch> findNext(
      const TextBuffer& buffer, SakuraStringView needle, TextOffset start,
      SearchOptions options = {}) const;
  [[nodiscard]] std::vector<SearchMatch> findAll(
      const TextBuffer& buffer, SakuraStringView needle,
      SearchOptions options = {}) const;
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_SEARCH_SEARCH_ENGINE_H_
