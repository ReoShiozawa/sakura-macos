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
  bool regexMultiline{true}; // ^/$ are logical line anchors; \A/\z remain document anchors.
  // Optional cancellation is checked during scanning and ICU backtracking.
  std::function<bool()> cancelled;
  // findAll only: zero means unlimited. replaceAll always processes all hits.
  std::size_t maxMatches{};
  std::int32_t regexTimeLimitMilliseconds{1000};
  // Replacement output cap; replaceAll also caps aggregate text/final document.
  // Single replacement does not reject an already larger source document.
  std::size_t maxReplacementCodeUnits{};
  // Optional UTF-16 matching region. Lookaround/anchors retain full-source
  // context; the complete match must stay in this region. Invalid bounds throw.
  std::optional<TextRange> range;
  bool captureGroups{true}; // false for highlighting/counting; keeps only full match ranges.
  std::size_t maxCaptureSlots{1048576};
  std::size_t maxReplacementMatches{1000000}; // Zero forbids replacements; overflow throws before any edit.
};

struct SearchMatch {
  TextRange range;
  // Absolute UTF-16 capture ranges from the original document. Entry zero is
  // the entire match; unmatched optional groups have no range.
  std::vector<std::optional<TextRange>> captures;
  friend constexpr bool operator==(const SearchMatch&, const SearchMatch&) = default;
};

// UTF-16 search over the document model. Case-insensitive literal matching
// uses ICU Unicode case folding (with original-source UTF-16 ranges).
// Whole words use Unicode letters/marks/numbers/connectors, not ASCII only.
// Regular expressions use ICU Unicode syntax;
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
      std::optional<std::size_t> outputLimit = std::nullopt,
      const std::function<bool()>& cancelled = {});
  // Read only referenced original-source ranges from a retained root. Expansion
  // and its output limits are identical; no full-source serialization is needed.
  [[nodiscard]] static SakuraString expandReplacement(
      const TextBuffer& source, const SearchMatch& match,
      SakuraStringView replacement,
      std::optional<std::size_t> outputLimit = std::nullopt,
      const std::function<bool()>& cancelled = {});
  [[nodiscard]] std::optional<SearchMatch> findNext(
      const TextBuffer& buffer, SakuraStringView needle, TextOffset start,
      SearchOptions options = {}) const;
  // Previous non-overlapping match with start strictly before the cursor.
  // If none precedes it, wrap optionally returns the last match in the region.
  // Streaming scan retains at most one candidate, not an array of all hits.
  [[nodiscard]] std::optional<SearchMatch> findPrevious(
      const TextBuffer& buffer, SakuraStringView needle, TextOffset cursor,
      SearchOptions options = {}) const;
  [[nodiscard]] std::vector<SearchMatch> findAll(
      const TextBuffer& buffer, SakuraStringView needle,
      SearchOptions options = {}) const;
};

}  // namespace sakura::core

#endif  // SAKURA_CORE_SEARCH_SEARCH_ENGINE_H_
